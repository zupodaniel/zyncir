import Foundation
import AppKit
import Network

/// Owns the menu-bar item, the autoconnect engine, and the clipboard bridge.
final class AppController: NSObject, NSApplicationDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var adb: Adb!
    private var discovery: MdnsDiscovery!
    private var bridge: ClipboardBridge!
    private let work = DispatchQueue(label: "zyncir.autoconnect")
    private let pathMonitor = NWPathMonitor()

    private var paired: PairedDevice?
    private var bridgeState: ClipboardBridge.State = .stopped
    private var connecting = false
    private var autoTimer: Timer?

    // Persistent menu and the items mutated on state changes, so an already-open
    // menu updates live (NSMenu is otherwise a snapshot taken when it opens).
    private let menu = NSMenu()
    private var statusMenuItem: NSMenuItem!
    private var reconnectItem: NSMenuItem!
    private var unpairItem: NSMenuItem!
    private var mirrorItem: NSMenuItem!
    private var mirrorSeparator: NSMenuItem!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let adb = Adb.locate() else {
            fatalAlert("adb not found",
                       "Install Android platform-tools (or open Android Studio once) and relaunch. " +
                       "You can also set the ADB or ANDROID_HOME environment variable.")
            return
        }
        guard let jarURL = Self.resolveJarURL() else {
            fatalAlert("zyncir.jar not found",
                       "The device helper jar is missing from the app bundle. Rebuild with build.sh.")
            return
        }

        self.adb = adb
        self.discovery = MdnsDiscovery(adb: adb)
        self.bridge = ClipboardBridge(adb: adb, jarURL: jarURL)
        self.paired = DeviceStore.load()

        bridge.onStateChange = { [weak self] state in
            self?.bridgeState = state
            self?.refreshUI()
        }

        buildMenu()
        refreshUI()
        startAutoConnect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
        pathMonitor.cancel()
    }

    private static func resolveJarURL() -> URL? {
        if let p = ProcessInfo.processInfo.environment["ZYNCIR_JAR"],
           FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return Bundle.module.url(forResource: "zyncir", withExtension: "jar")
    }

    // MARK: - Autoconnect engine

    private func startAutoConnect() {
        // Periodic tick.
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tickAutoConnect()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer

        // Network changes (e.g. phone rejoins Wi-Fi) trigger an immediate attempt.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.tickAutoConnect() }
        }
        pathMonitor.start(queue: work)

        tickAutoConnect()
    }

    private func tickAutoConnect() {
        guard !connecting else { return }
        connecting = true
        work.async { [weak self] in
            guard let self else { return }
            defer { self.connecting = false }
            // Read the target fresh: a device selection may have just changed it.
            guard let paired = self.paired else { return }

            // Primary: modern adb auto-connects paired wireless devices, so just
            // find our device among the connected transports (reliable, unlike
            // `adb mdns services`). bridge.start() is idempotent for the same
            // serial and switches transports if the selected device changed.
            if let target = self.targetSerial(for: paired, devices: self.adb.listDevices()) {
                self.bridge.start(serial: target)
                return
            }

            // Fallback: nudge a connection via mDNS discovery if adb has not
            // auto-connected yet, then re-resolve to a stable transport serial.
            if let svc = self.resolveConnectService(for: paired) {
                _ = try? self.adb.run(["connect", svc.endpoint])
                let target = self.targetSerial(for: paired, devices: self.adb.listDevices()) ?? svc.endpoint
                self.bridge.start(serial: target)
            }
        }
    }

    /// Pick the connected transport for the paired device. Prefers the stable
    /// mDNS transport (`adb-<serial>-…`) over a USB or raw IP:port transport.
    private func targetSerial(for paired: PairedDevice, devices: [Adb.DeviceEntry]) -> String? {
        let online = devices.filter { $0.state == "device" }
        guard let hw = paired.serial else {
            // Legacy pairing without a captured serial: only safe if there is a
            // single wireless transport to choose from.
            let wireless = online.filter { $0.isMdnsTransport }
            return wireless.count == 1 ? wireless.first?.serial : nil
        }
        // The Wi-Fi (mDNS) transport name embeds the serial; the USB transport
        // serial IS the hardware serial.
        let wifi = online.first { $0.isMdnsTransport && $0.serial.contains(hw) }
        let usb = online.first { !$0.isWireless && $0.serial == hw }
        // Honor the user's chosen transport, but fall back to the other if the
        // preferred one is not currently connected (e.g. cable unplugged).
        if paired.preferUSB == true {
            return usb?.serial ?? wifi?.serial
        }
        return wifi?.serial ?? usb?.serial
    }

    /// Find the connect service for the paired device, most specific first:
    /// exact mDNS instance name → instance name containing the hardware serial →
    /// the sole connect service if exactly one is advertised (single-device case).
    private func resolveConnectService(for paired: PairedDevice) -> MdnsService? {
        let connects = discovery.services(ofType: .connect)
        if let exact = connects.first(where: { $0.instanceName == paired.mdnsInstanceName }) {
            return exact
        }
        if let serial = paired.serial,
           let bySerial = connects.first(where: { $0.instanceName.contains(serial) }) {
            return bySerial
        }
        return connects.count == 1 ? connects.first : nil
    }

    // MARK: - Pairing & device selection

    /// First-time wireless setup. mDNS discovery of the pairing endpoint is
    /// unreliable, so we accept manual "IP:PORT" entry as well. After `adb pair`,
    /// identity is established by explicit selection (see `chooseAndAdopt`), which
    /// is robust even when the phone is already a connected adb device.
    @objc private func pairDevice() {
        work.async { [weak self] in
            guard let self else { return }
            let discovered = self.discovery.firstService(type: .pairing)
            DispatchQueue.main.async {
                guard let input = self.promptForPairing(suggestedHost: discovered?.endpoint) else { return }
                self.work.async {
                    do {
                        _ = try self.adb.run(["pair", input.endpoint, input.code])
                    } catch {
                        DispatchQueue.main.async { self.infoAlert("Pairing failed", "\(error)") }
                        return
                    }
                    // Give adb a few seconds to auto-connect the new device.
                    for _ in 0..<10 where self.adb.listDevices().contains(where: { $0.state == "device" && $0.isWireless }) == false {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    self.chooseAndAdopt(preferWireless: true)
                }
            }
        }
    }

    /// Choose which connected device to sync with. Works without pairing for any
    /// device adb already sees (USB or already-paired Wi-Fi). This is the reliable
    /// identity step — no dependence on the flaky `adb mdns services` listing.
    @objc private func selectDevice() {
        work.async { [weak self] in self?.chooseAndAdopt(preferWireless: false) }
    }

    /// Runs on the `work` queue. Lists connected non-emulator devices, auto-picks
    /// if there is exactly one, otherwise prompts, then stores the hardware serial.
    private func chooseAndAdopt(preferWireless: Bool) {
        let online = adb.listDevices().filter { $0.state == "device" && !$0.isEmulator }

        // One physical phone can expose several transports. Offer USB and Wi-Fi as
        // separate, selectable choices (keyed by model + kind), but collapse exact
        // duplicates — e.g. a phone's IP:PORT and mDNS transports are both "Wi-Fi",
        // so keep the stable mDNS one. (Selection is tag-bound, so identical titles
        // are harmless, but this keeps the list clean.)
        var groups: [String: Adb.DeviceEntry] = [:]
        var order: [String] = []
        for e in online {
            let kind = e.isWireless ? "wifi" : "usb"
            let key = "\(e.model ?? e.serial)|\(kind)"
            if let existing = groups[key] {
                if !existing.isMdnsTransport && e.isMdnsTransport { groups[key] = e } // prefer mDNS within Wi-Fi
            } else {
                groups[key] = e
                order.append(key)
            }
        }
        let candidates = order.compactMap { groups[$0] }
        NSLog("zyncir: device candidates: " + candidates.map { "\($0.displayName)[\($0.serial)]" }.joined(separator: ", "))

        guard !candidates.isEmpty else {
            DispatchQueue.main.async {
                self.infoAlert("No devices found",
                               "Connect the phone over USB, or enable Wireless debugging and pair first.")
            }
            return
        }

        if candidates.count == 1 {
            adopt(entry: candidates[0])
            return
        }
        DispatchQueue.main.async {
            guard let chosen = self.promptForDevice(candidates, current: self.paired) else { return }
            self.work.async { self.adopt(entry: chosen) }
        }
    }

    /// Store the chosen device by its stable hardware serial (read via getprop),
    /// then connect. Runs on the `work` queue.
    private func adopt(entry: Adb.DeviceEntry) {
        let hw = (try? adb.run(serial: entry.serial, ["shell", "getprop", "ro.serialno"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = (hw?.isEmpty == false) ? hw : entry.serial
        let preferUSB = !entry.isWireless
        NSLog("zyncir: adopting \(entry.displayName) transport=\(entry.serial) -> serial=\(serial ?? "nil") preferUSB=\(preferUSB)")
        let device = PairedDevice(mdnsInstanceName: "",
                                  serial: serial,
                                  lastKnownHost: nil,
                                  label: entry.model?.replacingOccurrences(of: "_", with: " ") ?? serial,
                                  preferUSB: preferUSB)
        DispatchQueue.main.async {
            self.paired = device
            DeviceStore.save(device)
            self.refreshUI()
            // Switch now even if the bridge is currently connected to another
            // device — tickAutoConnect reads the freshly stored target.
            self.tickAutoConnect()
        }
    }

    @objc private func reconnectNow() {
        tickAutoConnect()
    }

    /// Launch scrcpy against the current device, preferring its USB transport
    /// (smoother than Wi-Fi) regardless of the clipboard transport pin.
    @objc private func mirrorScreen() {
        work.async { [weak self] in
            guard let self else { return }
            guard let paired = self.paired else {
                DispatchQueue.main.async {
                    self.infoAlert("No device selected", "Select a device first, then mirror its screen.")
                }
                return
            }
            guard let scrcpy = Scrcpy.locate() else {
                DispatchQueue.main.async {
                    self.infoAlert("scrcpy not found",
                                   "Install it with “brew install scrcpy”, then try again. " +
                                   "You can also set the SCRCPY environment variable to its path.")
                }
                return
            }
            let devices = self.adb.listDevices()
            guard let target = self.mirrorTargetSerial(for: paired, devices: devices) else {
                DispatchQueue.main.async {
                    self.infoAlert("Device offline", "The selected device is not currently connected.")
                }
                return
            }
            do {
                try Scrcpy.launch(path: scrcpy, adbPath: self.adb.path, serial: target)
                NSLog("zyncir: launched scrcpy on \(target)")
            } catch {
                DispatchQueue.main.async { self.infoAlert("Could not start scrcpy", "\(error)") }
            }
        }
    }

    /// Like targetSerial, but always prefers USB for mirroring (better latency),
    /// falling back to the device's normal transport.
    private func mirrorTargetSerial(for paired: PairedDevice, devices: [Adb.DeviceEntry]) -> String? {
        let online = devices.filter { $0.state == "device" }
        if let hw = paired.serial,
           let usb = online.first(where: { !$0.isWireless && $0.serial == hw }) {
            return usb.serial
        }
        return targetSerial(for: paired, devices: devices)
    }

    @objc private func unpair() {
        bridge.stop()
        paired = nil
        DeviceStore.clear()
        refreshUI()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - UI

    /// Build the menu once with persistent item references. refreshUI() then
    /// mutates those items in place so changes show even while the menu is open.
    private func buildMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "zyncir")
        }
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        mirrorItem = NSMenuItem(title: "Mirror screen (scrcpy)", action: #selector(mirrorScreen), keyEquivalent: "m")
        mirrorItem.target = self
        menu.addItem(mirrorItem)
        mirrorSeparator = NSMenuItem.separator()
        menu.addItem(mirrorSeparator)

        let selectItem = NSMenuItem(title: "Select device…", action: #selector(selectDevice), keyEquivalent: "s")
        selectItem.target = self
        menu.addItem(selectItem)

        let pairItem = NSMenuItem(title: "Pair new device (Wi-Fi)…", action: #selector(pairDevice), keyEquivalent: "p")
        pairItem.target = self
        menu.addItem(pairItem)

        reconnectItem = NSMenuItem(title: "Reconnect now", action: #selector(reconnectNow), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        unpairItem = NSMenuItem(title: "Forget device", action: #selector(unpair), keyEquivalent: "")
        unpairItem.target = self
        menu.addItem(unpairItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit zyncir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Mutates the persistent menu items and the status glyph. Must run on the
    /// main thread (callers dispatch there).
    private func refreshUI() {
        let statusText: String
        switch (paired, bridgeState) {
        case (nil, _):
            statusText = "No device paired"
        case (_, .connected):
            statusText = "Connected: \(paired?.label ?? "device")"
        case (_, .connecting):
            statusText = "Connecting…"
        default:
            statusText = "Paired – phone offline"
        }
        statusMenuItem.title = statusText

        let hasPaired = (paired != nil)
        reconnectItem.isHidden = !hasPaired
        unpairItem.isHidden = !hasPaired
        mirrorItem.isHidden = !hasPaired
        mirrorSeparator.isHidden = !hasPaired

        // Reflect connection state in the menu-bar glyph.
        if let button = statusItem.button {
            let symbol = bridgeState == .connected ? "doc.on.clipboard.fill" : "doc.on.clipboard"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "zyncir")
        }
    }

    private func promptForPairing(suggestedHost: String?) -> (endpoint: String, code: String)? {
        let alert = NSAlert()
        alert.messageText = "Pair over Wi-Fi"
        alert.informativeText = "On the phone: Developer options → Wireless debugging → " +
            "“Pair device with pairing code”. Enter the IP address & port and the 6-digit code shown there."
        if let icon = symbolIcon("antenna.radiowaves.left.and.right") { alert.icon = icon }
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")

        let container = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        hostField.placeholderString = "192.168.0.42:37123"
        if let s = suggestedHost { hostField.stringValue = s }
        let codeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        codeField.placeholderString = "Pairing code (123456)"
        container.addArrangedSubview(hostField)
        container.addArrangedSubview(codeField)
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let endpoint = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty, !code.isEmpty else { return nil }
        return (endpoint, code)
    }

    /// Render an SF Symbol at alert-icon size. Replaces the default app/“folder”
    /// icon NSAlert shows for an unbundled executable.
    private func symbolIcon(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func promptForDevice(_ candidates: [Adb.DeviceEntry], current: PairedDevice?) -> Adb.DeviceEntry? {
        let alert = NSAlert()
        alert.messageText = "Select device to sync"
        alert.informativeText = "Choose the phone whose clipboard should stay in sync."
        // Connectivity glyph instead of the generic default icon.
        if let icon = symbolIcon("antenna.radiowaves.left.and.right") { alert.icon = icon }
        alert.addButton(withTitle: "Use device")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        // Bind by an explicit tag, not position: NSPopUpButton removes items with
        // duplicate titles, which would otherwise misalign index → candidate.
        for (i, c) in candidates.enumerated() {
            popup.addItem(withTitle: "\(c.displayName)  [\(c.serial)]")
            popup.lastItem?.tag = i
        }

        // Preselect the currently-synced device (matching its preferred transport)
        // so the dialog opens on it rather than defaulting to the first item.
        if let idx = currentSelectionIndex(in: candidates, for: current) {
            popup.selectItem(withTag: idx)
        }
        alert.accessoryView = popup

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let idx = popup.selectedItem?.tag ?? -1
        return (idx >= 0 && idx < candidates.count) ? candidates[idx] : nil
    }

    /// Index of the candidate that represents the currently-synced device,
    /// preferring the transport kind the user previously chose.
    private func currentSelectionIndex(in candidates: [Adb.DeviceEntry], for current: PairedDevice?) -> Int? {
        guard let hw = current?.serial else { return nil }
        let preferUSB = current?.preferUSB == true
        let matches = candidates.enumerated().filter { (_, c) in
            (!c.isWireless && c.serial == hw) || (c.isMdnsTransport && c.serial.contains(hw))
        }
        // Prefer the kind the device is pinned to; otherwise the first match.
        return matches.first(where: { preferUSB ? !$0.element.isWireless : $0.element.isWireless })?.offset
            ?? matches.first?.offset
    }

    private func infoAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func fatalAlert(_ title: String, _ message: String) {
        infoAlert(title, message)
        NSApp.terminate(nil)
    }
}
