import Foundation

/// Persists the identity of the one paired device. The mDNS instance name is the
/// stable identity across IP/port changes; the last-known serial (ip:port) is a
/// hint used only for the port-scan fallback.
struct PairedDevice: Codable {
    var mdnsInstanceName: String
    /// Hardware serial (ro.serialno). The connect-service mDNS name embeds it
    /// (e.g. "adb-<serial>-<suffix>"), making it the most stable match key.
    var serial: String?
    var lastKnownHost: String?
    var label: String?
    /// If true, prefer the USB transport for this device; otherwise prefer Wi-Fi.
    /// Optional for backward compatibility with previously stored pairings.
    var preferUSB: Bool?
}

enum DeviceStore {
    private static let key = "pairedDevice"

    // Explicit suite: a bare SwiftPM executable has no bundle identifier, so
    // UserDefaults.standard would write to an unstable domain and could lose the
    // pairing across launches. A named suite persists to a stable plist.
    private static let defaults = UserDefaults(suiteName: "com.zyncir") ?? .standard

    static func load() -> PairedDevice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    static func save(_ device: PairedDevice) {
        if let data = try? JSONEncoder().encode(device) {
            defaults.set(data, forKey: key)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: key)
    }
}
