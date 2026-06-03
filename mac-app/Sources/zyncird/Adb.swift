import Foundation

/// Locates and invokes the developer's existing `adb` binary.
///
/// Coexistence rules (see plan): we deliberately reuse the same adb the user's
/// Android Studio uses so the shared adb server (port 5037) is never killed by a
/// version mismatch, and we never spawn a private-port server. Every device
/// command is qualified with `-s <serial>` so we never disturb the IDE's
/// selected device or trip "more than one device".
struct Adb {

    enum AdbError: Error, CustomStringConvertible {
        case notFound
        case failed(command: String, status: Int32, stderr: String)

        var description: String {
            switch self {
            case .notFound:
                return "adb not found. Install Android platform-tools or set ANDROID_HOME."
            case let .failed(command, status, stderr):
                return "adb \(command) failed (exit \(status)): \(stderr)"
            }
        }
    }

    let path: String

    /// Resolve adb from the same locations Android Studio uses, preferring the
    /// SDK platform-tools so client/server versions match.
    static func locate() -> Adb? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let p = env["ADB"] { candidates.append(p) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = env[key] { candidates.append("\(sdk)/platform-tools/adb") }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")

        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return Adb(path: c)
        }
        // Last resort: PATH lookup.
        if let p = try? Adb(path: "/usr/bin/env").runRaw(["which", "adb"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) {
            return Adb(path: p)
        }
        return nil
    }

    @discardableResult
    func run(_ args: [String]) throws -> String {
        return try runRaw(args)
    }

    /// Run an adb command targeting a specific device serial.
    @discardableResult
    func run(serial: String, _ args: [String]) throws -> String {
        return try runRaw(["-s", serial] + args)
    }

    func runRaw(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw AdbError.failed(command: args.joined(separator: " "),
                                  status: process.terminationStatus,
                                  stderr: err.isEmpty ? out : err)
        }
        return out
    }

    struct DeviceEntry {
        let serial: String   // "EV501L016462", "192.168.0.101:38225", or "adb-XXXX-YY._adb-tls-connect._tcp"
        let state: String    // "device", "offline", "unauthorized", ...
        let model: String?   // e.g. "24044RN32L" (from `model:` in -l output)
        var isWireless: Bool { serial.hasPrefix("adb-") || serial.contains(":") }
        var isMdnsTransport: Bool { serial.hasPrefix("adb-") }
        var isEmulator: Bool { serial.hasPrefix("emulator-") }

        var displayName: String {
            let name = model?.replacingOccurrences(of: "_", with: " ") ?? serial
            let kind = isWireless ? "Wi-Fi" : (isEmulator ? "emulator" : "USB")
            return "\(name) — \(kind)"
        }
    }

    /// Parse `adb devices -l`. This is the reliable signal for what is connected;
    /// modern adb auto-connects paired wireless devices, while `adb mdns services`
    /// often returns empty once a device is already connected.
    func listDevices() -> [DeviceEntry] {
        guard let out = try? run(["devices", "-l"]) else { return [] }
        var result: [DeviceEntry] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of") { continue }
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init).filter { !$0.isEmpty }
            guard cols.count >= 2 else { continue }
            var model: String?
            for col in cols.dropFirst(2) where col.hasPrefix("model:") {
                model = String(col.dropFirst("model:".count))
            }
            result.append(DeviceEntry(serial: cols[0], state: cols[1], model: model))
        }
        return result
    }

    /// Launch a long-running adb command (the device-side helper). The returned
    /// Process keeps running until terminated; the caller owns its lifecycle.
    func launch(serial: String, _ args: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-s", serial] + args
        // Discard helper stdout/stderr; it must never carry clipboard content,
        // and we do not surface device logs in the menu-bar app.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
