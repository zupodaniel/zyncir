import Foundation
import AppKit
import UserNotifications

/// File transfer between the Mac and the paired device, layered on `adb push` /
/// `adb pull`. Bytes travel through those separate adb processes, never over the
/// clipboard bridge's socket.
///
/// Mac → device: `sendFiles` pushes into `/sdcard/Download/zyncir/`.
/// device → Mac: while connected, a poll of `/sdcard/Download/zyncir/send/` pulls
/// any new file into ~/Downloads, deletes the device copy, and drops the pulled
/// file on the pasteboard so it can be pasted immediately.
///
/// The active serial and all push/pull work live on `ops` (a serial queue), so
/// rapid transfers queue rather than spawn unbounded adb processes.
final class FileTransfer: NSObject {

    /// Files sent from the Mac land here (not polled).
    static let remoteInbox = "/sdcard/Download/zyncir"
    /// Watched: the user drops files here (from the phone's Files app) to send
    /// them to the Mac. A separate subfolder so a Mac→device push never echoes
    /// back as a device→Mac pull.
    static let remoteOutbox = "/sdcard/Download/zyncir/send"
    /// Don't auto-pull anything larger than this: a huge file dropped in the
    /// outbox shouldn't silently start a long transfer. "Receive latest" ignores
    /// the cap (an explicit request).
    static let autoPullMaxBytes: Int64 = 100 * 1024 * 1024

    private let adb: Adb
    private let ops = DispatchQueue(label: "zyncir.filetransfer")
    private var pollTimer: Timer?

    /// The serial of the currently-synced transport, or nil. Touched only on `ops`.
    private var serial: String?

    /// Notification id → file to reveal in Finder when the notification is tapped.
    /// Main thread only.
    private var revealByID: [String: URL] = [:]

    /// Notification id → outbox file name to pull when its "Download" action is
    /// tapped (used for files over the auto-pull cap). Main thread only.
    private var largeFileByID: [String: String] = [:]

    /// Outbox file names already surfaced as over-cap, so the poll doesn't
    /// re-notify every tick. Touched only on `ops`.
    private var notifiedLarge: Set<String> = []

    private static let largeFileCategory = "ZYNCIR_LARGE_FILE"
    private static let downloadAction = "ZYNCIR_DOWNLOAD"

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

    init(adb: Adb) {
        self.adb = adb
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let download = UNNotificationAction(identifier: Self.downloadAction, title: "Download", options: [])
        let category = UNNotificationCategory(identifier: Self.largeFileCategory,
                                              actions: [download], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
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
            }
        }
    }

    func startOutboxPolling() {
        stopOutboxPolling()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.drainOutbox()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopOutboxPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
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

    /// Pull one over-cap outbox file on demand (from its notification's "Download"
    /// action), ignoring the auto-pull size cap.
    func receiveLargeFile(name: String) {
        ops.async { [weak self] in
            guard let self, let s = self.serial else { return }
            self.pullAndConsume(serial: s, name: name, auto: false)
        }
    }

    /// Cancel the in-flight pull (from the progress window). Terminating the adb
    /// process makes the pull exit non-zero, so `pullAndConsume` treats it as a
    /// failure: the partial `.part` is discarded and the device copy is kept.
    func cancelCurrentTransfer() {
        pullLock.lock()
        let proc = currentPull
        pullLock.unlock()
        proc?.terminate()
    }

    private func drainOutbox() {
        ops.async { [weak self] in
            guard let self, let s = self.serial else { return }
            let names = self.adb.listRemote(serial: s, dir: Self.remoteOutbox)
            // Forget over-cap flags for files no longer present (e.g. downloaded
            // or removed), so a later file reusing the name is surfaced again.
            self.notifiedLarge.formIntersection(names)
            for name in names {
                self.pullAndConsume(serial: s, name: name, auto: true)
            }
        }
    }

    /// Runs on `ops`. Pulls one outbox entry, then deletes the device copy only
    /// after verifying the local file exists. Non-files are ignored; oversized
    /// files are skipped during auto-pull.
    private func pullAndConsume(serial s: String, name rawName: String, auto: Bool) {
        // A listing entry should be a bare filename; guard against separators so a
        // hostile name can't escape the outbox.
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return }
        let remote = "\(Self.remoteOutbox)/\(name)"

        guard let stat = adb.remoteStat(serial: s, path: remote) else { return }
        guard stat.isRegularFile else { return }   // skip directories/specials
        if auto && stat.size > Self.autoPullMaxBytes {
            // Don't auto-pull a large file; surface it once with a Download action
            // so the transfer stays behind an explicit tap.
            if !notifiedLarge.contains(name) {
                notifiedLarge.insert(name)
                let sizeText = ByteCountFormatter.string(fromByteCount: stat.size, countStyle: .file)
                DispatchQueue.main.async { [weak self] in
                    self?.postLargeFileNotification(name: name, sizeText: sizeText)
                }
            }
            return
        }

        let total = stat.size
        let dest = Self.uniqueDownloadURL(for: name)
        // Pull into a sibling ".part" file so an interrupted transfer never looks
        // like a finished download, and so the device copy is deleted ONLY after
        // the pulled size is verified against the device size.
        let part = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)

        let proc: Process
        do {
            proc = try adb.launch(serial: s, ["pull", remote, part.path])
        } catch {
            NSLog("zyncir: pull launch failed: \(error)")
            return
        }
        pullLock.lock(); currentPull = proc; pullLock.unlock()
        if total >= Self.progressUIMinBytes {
            let partPath = part.path
            DispatchQueue.main.async { [weak self] in
                self?.startProgress(name: name, total: total, incoming: true) {
                    Self.fileSize(atPath: partPath)
                }
            }
        }
        proc.waitUntilExit()
        pullLock.lock(); currentPull = nil; pullLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.stopProgress() }

        let pulled = Self.fileSize(atPath: part.path)
        guard proc.terminationStatus == 0, let got = pulled, got == total else {
            NSLog("zyncir: pull incomplete (status \(proc.terminationStatus), got \(pulled.map(String.init) ?? "nil") of \(total)); keeping device copy")
            try? FileManager.default.removeItem(at: part)
            DispatchQueue.main.async { [weak self] in self?.onTransferFinished?(name, false) }
            return
        }
        do {
            try FileManager.default.moveItem(at: part, to: dest)
        } catch {
            NSLog("zyncir: finalize rename failed: \(error); keeping device copy")
            try? FileManager.default.removeItem(at: part)
            DispatchQueue.main.async { [weak self] in self?.onTransferFinished?(name, false) }
            return
        }
        adb.removeRemote(serial: s, path: remote)
        notifiedLarge.remove(name)
        DispatchQueue.main.async { [weak self] in
            self?.onTransferFinished?(name, true)
            self?.placeOnPasteboardAndNotify(dest)
        }
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

    private func postLargeFileNotification(name: String, sizeText: String) {
        let content = UNMutableNotificationContent()
        content.title = "Large file waiting on device"
        content.body = "\(name) (\(sizeText)) wasn’t downloaded automatically. Tap Download to receive it."
        content.categoryIdentifier = Self.largeFileCategory
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        largeFileByID[request.identifier] = name
        UNUserNotificationCenter.current().add(request)
    }

    private func postNotification(title: String, body: String, revealURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        if let revealURL { revealByID[request.identifier] = revealURL }
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
        let id = response.notification.request.identifier
        if let name = largeFileByID.removeValue(forKey: id) {
            // Both the "Download" action and tapping the banner body pull the file.
            receiveLargeFile(name: name)
        } else if let url = revealByID.removeValue(forKey: id) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        completionHandler()
    }
}
