import Foundation

/// Locates and launches scrcpy for screen mirroring. scrcpy is a separate,
/// optional tool (install via `brew install scrcpy`); zyncir only shells out
/// to it. We pass our adb path via the ADB env var so scrcpy talks to the same
/// adb server (no version-mismatch "killing server" churn).
enum Scrcpy {

    static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let p = env["SCRCPY"] { candidates.append(p) }
        candidates += ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // PATH lookup (inherited when launched from a shell).
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "scrcpy"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            which.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Launch scrcpy detached against a specific device serial. It runs in its own
    /// window until the user closes it. The returned Process lets the caller watch
    /// for an early non-zero exit (a startup/connection failure) via
    /// `terminationHandler`; the caller owns its lifetime.
    @discardableResult
    static func launch(path: String, adbPath: String, serial: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // --no-clipboard-autosync: zyncir already owns clipboard sync; letting
        // scrcpy also sync it would be redundant and could cause echo races.
        process.arguments = ["-s", serial, "--no-clipboard-autosync"]
        var env = ProcessInfo.processInfo.environment
        env["ADB"] = adbPath
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
