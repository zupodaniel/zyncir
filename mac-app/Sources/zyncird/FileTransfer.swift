import Foundation
import AppKit
import UserNotifications

/// File transfer between the Mac and the paired device.
///
/// Mac → device: `sendFiles` pushes into `/sdcard/Download/zyncir/` via `adb push`.
/// device → Mac: the share app streams files straight into ~/Downloads over the
/// `zyncir-share` socket (reached via `adb forward`) — no device-side copy. It
/// signals readiness with a tiny trigger file in `/sdcard/Download/zyncir/send/`,
/// which the helper's watcher relays so the Mac connects and reads the stream.
///
/// The active serial and all adb work live on `ops` (a serial queue), so rapid
/// transfers queue rather than spawn unbounded adb processes.
final class FileTransfer: NSObject {

    /// Files sent from the Mac land here (not polled).
    static let remoteInbox = "/sdcard/Download/zyncir"
    /// Watched: the user drops files here (from the phone's Files app) to send
    /// them to the Mac. A separate subfolder so a Mac→device push never echoes
    /// back as a device→Mac pull.
    static let remoteOutbox = "/sdcard/Download/zyncir/send"
    /// Reserved trigger file the share app drops to request a direct stream (no
    /// device-side copy) over the `zyncir-share` socket. Not a real transfer.
    static let streamMarker = "__zyncir_stream_request__"
    static let streamSocket = "zyncir-share"

    private let adb: Adb
    private let ops = DispatchQueue(label: "zyncir.filetransfer")

    /// The bundled "Share to zyncir" companion APK, installed/updated over adb on
    /// connect so the phone's share sheet gains a "zyncir" target.
    private let shareApkURL: URL?
    static let shareAppPackage = "com.zyncir.share"
    static let shareAppVersionCode = 4
    /// Serials whose share app has already been checked this session. On `ops`.
    private var ensuredShareApp: Set<String> = []

    /// The serial of the currently-synced transport, or nil. Touched only on `ops`.
    private var serial: String?

    private static let receivedCategory = "ZYNCIR_RECEIVED"
    private static let revealAction = "ZYNCIR_REVEAL"

    /// Called on the main thread right after a received file is written to the
    /// pasteboard, so the clipboard bridge can suppress the resulting change.
    var didWritePasteboard: (() -> Void)?

    /// Live progress for the current device→Mac pull, emitted ~1×/s on the main
    /// thread while a sizeable transfer is running.
    struct TransferProgress {
        let name: String
        let transferred: Int64
        let total: Int64
        let bytesPerSec: Double
        let eta: TimeInterval
        /// true = device→Mac (receiving), false = Mac→device (sending).
        let incoming: Bool
    }

    /// Only surface the progress UI for transfers at least this large; smaller
    /// files finish too quickly for a window to be useful.
    static let progressUIMinBytes: Int64 = 20 * 1024 * 1024

    var onTransferProgress: ((TransferProgress) -> Void)?
    var onTransferFinished: ((_ name: String, _ success: Bool) -> Void)?

    /// The running `adb pull`, so it can be cancelled from the UI. Guarded by
    /// `pullLock` because it is set on `ops` but read/terminated on the main
    /// thread, which must not block on `ops` (that queue is parked in
    /// `waitUntilExit` for the duration of the transfer).
    private let pullLock = NSLock()
    private var currentPull: Process?
    /// The in-flight direct-stream socket fd and its cancel flag (guarded by
    /// `pullLock`, since Cancel comes from the main thread).
    private var currentStreamFD: Int32?
    private var streamCancelled = false

    // Progress-sampling state — mutated on the main thread; `progressSampler` is
    // invoked on `sampleQueue` so a device-side stat never blocks the main thread.
    private let sampleQueue = DispatchQueue(label: "zyncir.filetransfer.sample")
    private var progressTimer: Timer?
    private var progressName: String?
    private var progressTotal: Int64 = 0
    private var progressIncoming = true
    private var progressSampler: (() -> Int64?)?
    private var progressSampling = false
    private var lastSampleSize: Int64 = 0
    private var lastSampleTime: Date?
    private var emaRate: Double = 0

    init(adb: Adb, shareApkURL: URL?) {
        self.adb = adb
        self.shareApkURL = shareApkURL
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.receivedCategory, actions: [reveal],
                                   intentIdentifiers: [], options: [])
        ])
    }

    // MARK: - Connection lifecycle (called by AppController)

    /// Point transfers at a device (or nil to detach). Creates the folders when a
    /// serial is set so both directions have somewhere to work.
    func setSerial(_ newSerial: String?) {
        ops.async { [weak self] in
            guard let self else { return }
            let changed = (self.serial != newSerial)
            self.serial = newSerial
            // Create the folders once per (re)connection, not on every tick.
            if changed, let s = newSerial {
                try? self.adb.mkdirp(serial: s, paths: [Self.remoteInbox, Self.remoteOutbox])
                self.ensureShareApp(serial: s)
            }
        }
    }

    /// Install (or update) the "Share to zyncir" companion APK on the device the
    /// first time we see a serial this session. Runs on `ops` (install is slow).
    private func ensureShareApp(serial s: String) {
        guard let apk = shareApkURL, !ensuredShareApp.contains(s) else { return }
        ensuredShareApp.insert(s)
        let installed = installedShareVersion(serial: s)
        if installed == nil || installed! < Self.shareAppVersionCode {
            NSLog("zyncir: installing share app on \(s) (installed=\(installed.map(String.init) ?? "none"))")
            _ = try? adb.run(serial: s, ["install", "-r", apk.path])
        }
    }

    /// The installed versionCode of the share app, or nil if not installed.
    private func installedShareVersion(serial s: String) -> Int? {
        guard let out = try? adb.run(serial: s, ["shell", "dumpsys", "package", Self.shareAppPackage]) else { return nil }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("versionCode=") {
                // e.g. "versionCode=1 minSdk=29 targetSdk=35"
                let rest = t.dropFirst("versionCode=".count)
                let digits = rest.prefix { $0.isNumber }
                return Int(digits)
            }
        }
        return nil
    }

    /// Pull whatever is currently in the staging drop. Driven by the helper's
    /// "file ready" signal (and once on connect) — no periodic polling.
    func triggerDrain() {
        drainOutbox()
    }

    // MARK: - Mac → device

    /// Push the given files into the device inbox. Safe to call from the main
    /// thread; work runs on `ops`.
    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        ops.async { [weak self] in
            guard let self, let s = self.serial else { return }
            try? self.adb.mkdirp(serial: s, paths: [Self.remoteInbox])
            var sent = 0
            var failed: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                let remote = "\(Self.remoteInbox)/\(name)"
                let total = Self.fileSize(atPath: url.path) ?? 0

                let proc: Process
                do {
                    proc = try self.adb.launch(serial: s, ["push", url.path, remote])
                } catch {
                    NSLog("zyncir: push launch failed: \(error)")
                    failed.append(name)
                    continue
                }
                self.pullLock.lock(); self.currentPull = proc; self.pullLock.unlock()
                if total >= Self.progressUIMinBytes {
                    DispatchQueue.main.async {
                        self.startProgress(name: name, total: total, incoming: false) { [weak self] in
                            self?.adb.remoteStat(serial: s, path: remote)?.size
                        }
                    }
                }
                proc.waitUntilExit()
                self.pullLock.lock(); self.currentPull = nil; self.pullLock.unlock()
                DispatchQueue.main.async { self.stopProgress() }

                // Verify the device received the whole file before counting it sent.
                if proc.terminationStatus == 0, self.adb.remoteStat(serial: s, path: remote)?.size == total {
                    self.adb.mediaScan(serial: s, path: remote)
                    sent += 1
                } else {
                    NSLog("zyncir: push incomplete for \(name) (status \(proc.terminationStatus))")
                    failed.append(name)
                }
            }
            DispatchQueue.main.async {
                self.onTransferFinished?(urls.first?.lastPathComponent ?? "", failed.isEmpty)
                if failed.isEmpty {
                    self.postNotification(title: "Sent to device",
                                          body: sent == 1 ? urls[0].lastPathComponent : "\(sent) files")
                } else {
                    self.postNotification(title: "Some files were not sent",
                                          body: failed.joined(separator: ", "))
                }
            }
        }
    }

    // MARK: - device → Mac

    /// Cancel the in-flight transfer from the progress window. For a direct
    /// stream this closes the socket, unblocking the read loop so the partial is
    /// discarded.
    func cancelCurrentTransfer() {
        pullLock.lock()
        let proc = currentPull
        let fd = currentStreamFD
        streamCancelled = true
        pullLock.unlock()
        proc?.terminate()
        if let fd { close(fd) }   // unblocks the stream read loop
    }

    /// Look for the share app's stream trigger in the drop and, if present,
    /// receive the file(s) directly over the socket. Files are never copied to
    /// the device; a plain file dropped into the folder by hand is ignored.
    private func drainOutbox() {
        ops.async { [weak self] in
            guard let self, let s = self.serial else { return }
            let names = self.adb.listRemote(serial: s, dir: Self.remoteOutbox)
            for name in names where name == Self.streamMarker {
                self.adb.removeRemote(serial: s, path: "\(Self.remoteOutbox)/\(name)")
                self.receiveStream(serial: s)
            }
        }
    }

    // MARK: - Direct stream receive (device→Mac, no staging copy)

    /// Runs on `ops`. Connects to the share app's socket via `adb forward` and
    /// writes each streamed file straight into ~/Downloads — no device-side copy,
    /// nothing to delete afterward.
    private func receiveStream(serial s: String) {
        guard let out = try? adb.run(serial: s, ["forward", "tcp:0", "localabstract:\(Self.streamSocket)"]),
              let port = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            NSLog("zyncir: stream forward failed"); return
        }
        defer { _ = try? adb.run(serial: s, ["forward", "--remove", "tcp:\(port)"]) }

        guard let fd = Self.connectLoopback(port: port) else {
            NSLog("zyncir: stream connect failed"); return
        }
        pullLock.lock(); currentStreamFD = fd; streamCancelled = false; pullLock.unlock()
        defer {
            pullLock.lock(); currentStreamFD = nil; pullLock.unlock()
            close(fd)
        }

        guard let count = Self.readInt32(fd), count > 0 else { return }
        for _ in 0..<count {
            guard let nameLen = Self.readUInt16(fd),
                  let nameData = Self.readExactly(fd, Int(nameLen)),
                  let name = String(data: nameData, encoding: .utf8),
                  let total = Self.readInt64(fd) else { return }
            if !receiveOneFile(fd: fd, rawName: name, total: total) { return }
        }
    }

    /// Stream one file's `total` bytes (or to EOF if total < 0) into a `.part`
    /// file, then finalize into ~/Downloads. Returns false to abort the batch.
    private func receiveOneFile(fd: Int32, rawName: String, total: Int64) -> Bool {
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let dest = Self.uniqueDownloadURL(for: name)
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
              let fh = try? FileHandle(forWritingTo: part) else { return false }

        let showUI = total >= Self.progressUIMinBytes
        if showUI {
            let partPath = part.path
            DispatchQueue.main.async { [weak self] in
                self?.startProgress(name: name, total: total, incoming: true) {
                    Self.fileSize(atPath: partPath)
                }
            }
        }

        var received: Int64 = 0
        var buf = [UInt8](repeating: 0, count: 262144)
        var aborted = false
        while total < 0 || received < total {
            pullLock.lock(); let cancelled = streamCancelled; pullLock.unlock()
            if cancelled { aborted = true; break }
            let want = total < 0 ? buf.count : Int(min(Int64(buf.count), total - received))
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n <= 0 { break }
            do { try fh.write(contentsOf: Data(buf[0..<n])) } catch { break }
            received += Int64(n)
        }
        try? fh.close()
        if showUI { DispatchQueue.main.async { [weak self] in self?.stopProgress() } }

        let complete = !aborted && (total < 0 ? received > 0 : received == total)
        guard complete else {
            try? FileManager.default.removeItem(at: part)
            DispatchQueue.main.async { [weak self] in self?.onTransferFinished?(name, false) }
            return false
        }
        do {
            try FileManager.default.moveItem(at: part, to: dest)
        } catch {
            NSLog("zyncir: stream finalize failed: \(error)")
            try? FileManager.default.removeItem(at: part)
            DispatchQueue.main.async { [weak self] in self?.onTransferFinished?(name, false) }
            return false
        }
        DispatchQueue.main.async { [weak self] in
            self?.onTransferFinished?(name, true)
            self?.placeOnPasteboardAndNotify(dest)
        }
        return true
    }

    // MARK: - Blocking socket read helpers (loopback via adb forward)

    private static func connectLoopback(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok { close(fd); return nil }
        return fd
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
        var remaining = count
        while remaining > 0 {
            let toRead = min(remaining, buf.count)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, toRead) }
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
            remaining -= n
        }
        return data
    }

    private static func readUInt16(_ fd: Int32) -> UInt16? {
        guard let d = readExactly(fd, 2) else { return nil }
        return (UInt16(d[0]) << 8) | UInt16(d[1])
    }

    private static func readInt32(_ fd: Int32) -> Int? {
        guard let d = readExactly(fd, 4) else { return nil }
        var v: UInt32 = 0
        for b in d { v = (v << 8) | UInt32(b) }
        return Int(v)
    }

    private static func readInt64(_ fd: Int32) -> Int64? {
        guard let d = readExactly(fd, 8) else { return nil }
        var v: UInt64 = 0
        for b in d { v = (v << 8) | UInt64(b) }
        return Int64(bitPattern: v)
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    // MARK: - Progress sampling

    /// Poll `sampler` (the transferred byte count) once a second and emit a
    /// smoothed rate + ETA. Works for both directions: the receive side samples
    /// the local `.part` file, the send side stats the growing device file.
    /// `sampler` runs on `sampleQueue`; all state mutation stays on the main
    /// thread. Call on the main thread.
    private func startProgress(name: String, total: Int64, incoming: Bool,
                               sampler: @escaping () -> Int64?) {
        stopProgress()
        progressName = name
        progressTotal = total
        progressIncoming = incoming
        progressSampler = sampler
        lastSampleSize = 0
        lastSampleTime = nil
        emaRate = 0
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tickProgress() }
        RunLoop.main.add(t, forMode: .common)
        progressTimer = t
        tickProgress()
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressName = nil
        progressSampler = nil
        progressSampling = false
    }

    private func tickProgress() {
        guard !progressSampling, let sampler = progressSampler else { return }
        progressSampling = true
        sampleQueue.async { [weak self] in
            let size = sampler()
            DispatchQueue.main.async { self?.applySample(size) }
        }
    }

    private func applySample(_ size: Int64?) {
        progressSampling = false
        guard let name = progressName else { return }   // stopped meanwhile
        let sz = size ?? lastSampleSize
        let now = Date()
        if let last = lastSampleTime {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                let inst = Double(sz - lastSampleSize) / dt
                emaRate = emaRate == 0 ? inst : (0.6 * emaRate + 0.4 * inst)
            }
        }
        lastSampleSize = sz
        lastSampleTime = now
        let remaining = max(0, progressTotal - sz)
        let eta = emaRate > 0 ? Double(remaining) / emaRate : .infinity
        onTransferProgress?(TransferProgress(name: name, transferred: sz, total: progressTotal,
                                             bytesPerSec: emaRate, eta: eta, incoming: progressIncoming))
    }

    /// A non-colliding URL in ~/Downloads: appends " (n)" before the extension.
    private static func uniqueDownloadURL(for name: String) -> URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var candidate = downloads.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = downloads.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: - Pasteboard & notifications (main thread)

    private func placeOnPasteboardAndNotify(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        didWritePasteboard?()   // keep the clipboard bridge from re-sending it as text
        postNotification(title: "Received from device", body: url.lastPathComponent, revealURL: url)
    }

    private func postNotification(title: String, body: String, revealURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let revealURL {
            // Carry the path in userInfo (not an in-memory map) so tapping the
            // banner — or the "Show in Finder" action — reveals the file even
            // after zyncir has relaunched.
            content.userInfo = ["revealPath": revealURL.path]
            content.categoryIdentifier = Self.receivedCategory
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension FileTransfer: UNUserNotificationCenterDelegate {
    // The app is a menu-bar accessory, so present banners even while it's active.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Both a banner tap (default action) and the "Show in Finder" button land
        // here — reveal the file in either case.
        if let path = response.notification.request.content.userInfo["revealPath"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            // activateFileViewerSelecting selects the file but doesn't focus
            // Finder when the caller is a background/accessory app — bring it front.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
                .first?.activate(options: [.activateAllWindows])
        }
        completionHandler()
    }
}
