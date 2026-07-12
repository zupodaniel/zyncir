import Foundation
import AppKit
import Network

/// Bridges the macOS pasteboard with the device-side helper over an
/// adb-forwarded TCP socket.
///
/// Direction Mac→device: poll NSPasteboard.changeCount (macOS has no change
/// callback); on a real change, frame and send the text.
/// Direction device→Mac: receive frames and write to NSPasteboard.
///
/// Wire protocol: 4-byte big-endian length + UTF-8 bytes (matches Server.java).
final class ClipboardBridge {

    enum State {
        case stopped
        case connecting
        case connected
    }

    private let adb: Adb
    private let jarURL: URL
    private let queue = DispatchQueue(label: "zyncir.bridge")

    private var serial: String?
    private var helper: Process?
    private var forwardPort: Int?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var helloReceived = false
    private var connectAttempt = 0

    // Loop guard — all access on the main queue.
    private var lastValue: String?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var pollTimer: Timer?

    private(set) var state: State = .stopped
    var onStateChange: ((State) -> Void)?

    init(adb: Adb, jarURL: URL) {
        self.adb = adb
        self.jarURL = jarURL
    }

    // MARK: - Lifecycle

    /// Idempotent: if already bridging this serial and connected, do nothing.
    func start(serial: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.serial == serial, self.state != .stopped { return }
            self.teardownLocked()
            self.serial = serial
            self.setState(.connecting)
            do {
                self.connectAttempt = 0
                try self.deployHelperLocked(serial: serial)
                try self.openForwardLocked(serial: serial)
                self.connectSocketLocked()
            } catch {
                NSLog("zyncir: bridge start failed: \(error)")
                self.teardownLocked()
                self.setState(.stopped)
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardownLocked()
            self?.setState(.stopped)
        }
    }

    // MARK: - Device helper deployment (queue)

    private func deployHelperLocked(serial: String) throws {
        // Kill any stale/orphaned helper first so the localabstract socket is free
        // and only one instance runs (avoids "address already in use").
        _ = try? adb.run(serial: serial, ["shell", "pkill", "-f", "com.zyncir"])
        try adb.run(serial: serial, ["push", jarURL.path, "/data/local/tmp/zyncir.jar"])
        // Long-running; binds localabstract:zyncir as the shell user.
        helper = try adb.launch(serial: serial,
                                ["shell", "CLASSPATH=/data/local/tmp/zyncir.jar",
                                 "app_process", "/", "com.zyncir.Server"])
        NSLog("zyncir: helper launched on \(serial)")
    }

    private func openForwardLocked(serial: String) throws {
        // tcp:0 asks adb to allocate a free host port; it prints the number.
        let out = try adb.run(serial: serial, ["forward", "tcp:0", "localabstract:zyncir"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed) else {
            throw NSError(domain: "zyncir", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "adb forward returned no port: \(trimmed)"])
        }
        forwardPort = port
        NSLog("zyncir: forward tcp:\(port) -> localabstract:zyncir")
    }

    private static let maxConnectAttempts = 30 // ~15s at 0.5s spacing

    /// Connect and wait for the helper's hello frame. TCP `.ready` is NOT proof of
    /// readiness: adb accepts the host port even before the device socket exists
    /// and then drops the connection. So we retry (WITHOUT killing the helper,
    /// which is still starting up) until a hello frame arrives or we exhaust
    /// attempts. Only a drop AFTER we are connected tears things down.
    private func connectSocketLocked() {
        guard let port = forwardPort, let portObj = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let conn = NWConnection(host: "127.0.0.1", port: portObj, using: .tcp)
        connection = conn
        helloReceived = false
        receiveBuffer.removeAll()

        // Per-attempt watchdog: if no hello within the window, retry.
        queue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if self.connection === conn, self.state == .connecting, !self.helloReceived {
                self.retryConnect(after: conn)
            }
        }

        conn.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                switch nwState {
                case .ready:
                    // Start reading; do not declare connected until the hello frame.
                    self.startReceiving(on: conn)
                case .failed, .cancelled:
                    if self.state == .connecting {
                        self.retryConnect(after: conn)
                    }
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    /// Retry the next connect attempt, or give up (killing the helper) once the
    /// attempt budget is exhausted. Runs on `queue`.
    private func retryConnect(after conn: NWConnection) {
        guard connection === conn else { return }
        conn.cancel()
        connection = nil
        connectAttempt += 1
        if connectAttempt < Self.maxConnectAttempts {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.state == .connecting else { return }
                self.connectSocketLocked()
            }
        } else {
            NSLog("zyncir: gave up connecting after \(connectAttempt) attempts")
            teardownLocked()
            setState(.stopped)
        }
    }

    private func teardownLocked() {
        DispatchQueue.main.async { [weak self] in self?.stopPolling() }
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        helloReceived = false
        if let s = serial, let p = forwardPort {
            _ = try? adb.run(serial: s, ["forward", "--remove", "tcp:\(p)"])
        }
        forwardPort = nil
        helper?.terminate()
        helper = nil
        // Terminating the local adb client can orphan the device process; ensure
        // the device-side helper is gone so it does not hold the socket.
        if let s = serial {
            _ = try? adb.run(serial: s, ["shell", "pkill", "-f", "com.zyncir"])
        }
    }

    private func setState(_ newState: State) {
        state = newState
        let cb = onStateChange
        DispatchQueue.main.async { cb?(newState) }
    }

    // MARK: - Receiving (queue) : device → Mac

    private func startReceiving(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.drainFrames()
                }
                if isComplete || error != nil {
                    if self.state == .connecting {
                        // Dropped before the handshake completed (adb accepted the
                        // host port before the device socket was ready) — retry.
                        self.retryConnect(after: conn)
                    } else if self.state == .connected {
                        // A real drop after connecting; let autoconnect recover.
                        self.teardownLocked()
                        self.setState(.stopped)
                    }
                    return
                }
                self.startReceiving(on: conn)
            }
        }
    }

    /// Runs on `queue`. The first frame (the helper's hello) confirms readiness.
    private func drainFrames() {
        while receiveBuffer.count >= 4 {
            let len = Int(receiveBuffer[0]) << 24 | Int(receiveBuffer[1]) << 16
                    | Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
            if len < 0 || receiveBuffer.count < 4 + len { break }
            let payload = receiveBuffer.subdata(in: 4..<(4 + len))
            receiveBuffer.removeSubrange(0..<(4 + len))

            if !helloReceived {
                helloReceived = true
                NSLog("zyncir: connected (hello received)")
                setState(.connected)
                DispatchQueue.main.async { [weak self] in self?.startPolling() }
            }
            if len > 0, let text = String(data: payload, encoding: .utf8) {
                DispatchQueue.main.async { [weak self] in self?.applyFromDevice(text) }
            }
        }
    }

    // MARK: - Pasteboard (main) : Mac → device

    private func startPolling() {
        stopPolling()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string) else { return }
        if text == lastValue { return }   // loop guard
        lastValue = text
        send(text)
    }

    /// Align the loop guard with the current pasteboard state so a change made by
    /// something other than this bridge (e.g. a received file URL written by
    /// FileTransfer) is not read on the next poll and re-sent to the device. Call
    /// on the main thread, after the pasteboard write.
    func suppressNextPasteboardChange() {
        let pb = NSPasteboard.general
        lastChangeCount = pb.changeCount
    }

    /// device → Mac. Sets the pasteboard without re-sending it back.
    private func applyFromDevice(_ text: String) {
        if text == lastValue { return }   // loop guard
        lastValue = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount  // suppress the poll echo
    }

    private func send(_ text: String) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection, self.state == .connected else { return }
            let bytes = Array(text.utf8)
            var frame = Data(count: 4)
            let len = bytes.count
            frame[0] = UInt8((len >> 24) & 0xff)
            frame[1] = UInt8((len >> 16) & 0xff)
            frame[2] = UInt8((len >> 8) & 0xff)
            frame[3] = UInt8(len & 0xff)
            frame.append(contentsOf: bytes)
            conn.send(content: frame, completion: .contentProcessed { error in
                if let error { NSLog("zyncir: send error: \(error)") }
            })
        }
    }
}
