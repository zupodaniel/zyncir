import Foundation
import Network

/// Connects to the helper's dedicated "zyncir-files" socket (via `adb forward`)
/// and invokes `onSignal` whenever the helper reports a file landing in the
/// staging drop, so the Mac pulls immediately instead of polling. Independent of
/// the clipboard bridge's socket and protocol.
final class FileSignalClient {

    var onSignal: (() -> Void)?

    private let adb: Adb
    private let queue = DispatchQueue(label: "zyncir.filesignal")
    private var serial: String?
    private var forwardPort: Int?
    private var connection: NWConnection?
    private var active = false

    init(adb: Adb) { self.adb = adb }

    /// Idempotent: reconnects only if the serial changed or it isn't running.
    func start(serial: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.active, self.serial == serial { return }
            self.teardownLocked()
            self.serial = serial
            self.active = true
            self.openAndConnectLocked()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.active = false
            self.teardownLocked()
        }
    }

    // MARK: - Queue-confined

    private func openAndConnectLocked() {
        guard active, let s = serial else { return }
        guard let out = try? adb.run(serial: s, ["forward", "tcp:0", "localabstract:zyncir-files"]),
              let port = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)),
              let portObj = NWEndpoint.Port(rawValue: UInt16(port)) else {
            retryLocked()
            return
        }
        forwardPort = port
        let conn = NWConnection(host: "127.0.0.1", port: portObj, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                switch state {
                case .ready:
                    self.receive(on: conn)
                case .failed, .cancelled:
                    if self.active { self.retryLocked() }
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard self.connection === conn else { return }
                if let data, !data.isEmpty {
                    // Any data means "a file is ready" — pull the drop (idempotent).
                    let cb = self.onSignal
                    DispatchQueue.main.async { cb?() }
                }
                if isComplete || error != nil {
                    if self.active { self.retryLocked() }
                    return
                }
                self.receive(on: conn)
            }
        }
    }

    private func retryLocked() {
        connection?.cancel()
        connection = nil
        removeForwardLocked()
        guard active else { return }
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.active else { return }
            self.openAndConnectLocked()
        }
    }

    private func removeForwardLocked() {
        if let s = serial, let p = forwardPort {
            _ = try? adb.run(serial: s, ["forward", "--remove", "tcp:\(p)"])
        }
        forwardPort = nil
    }

    private func teardownLocked() {
        connection?.cancel()
        connection = nil
        removeForwardLocked()
    }
}
