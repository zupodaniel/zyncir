import Foundation

/// A single mDNS service instance as reported by `adb mdns services`.
struct MdnsService {
    let instanceName: String   // e.g. "adb-1A2B3C4D-eFgHiJ"
    let serviceType: String    // "_adb-tls-connect._tcp" or "_adb-tls-pairing._tcp"
    let host: String           // IPv4 address
    let port: Int

    var endpoint: String { "\(host):\(port)" }
}

enum AdbServiceType: String {
    case connect = "_adb-tls-connect._tcp"
    case pairing = "_adb-tls-pairing._tcp"
}

/// Discovers wireless-debugging endpoints through adb's built-in mDNS stack.
/// macOS runs mDNSResponder always-on, so no extra daemon is required.
struct MdnsDiscovery {
    let adb: Adb

    func services() -> [MdnsService] {
        guard let output = try? adb.run(["mdns", "services"]) else {
            return []
        }
        return MdnsDiscovery.parse(output)
    }

    /// Parse the tab/space separated table. Example lines:
    ///   List of discovered mdns services
    ///   adb-1A2B3C4D-eFgHiJ   _adb-tls-connect._tcp   192.168.1.5:39871
    static func parse(_ output: String) -> [MdnsService] {
        var result: [MdnsService] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of") { continue }
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard cols.count >= 3 else { continue }
            let name = cols[0]
            let type = cols[1]
            let addr = cols[2]
            guard let colon = addr.lastIndex(of: ":") else { continue }
            let host = String(addr[addr.startIndex..<colon])
            guard let port = Int(addr[addr.index(after: colon)...]) else { continue }
            result.append(MdnsService(instanceName: name, serviceType: type, host: host, port: port))
        }
        return result
    }

    func service(named instanceName: String, type: AdbServiceType) -> MdnsService? {
        services().first { $0.instanceName == instanceName && $0.serviceType == type.rawValue }
    }

    func firstService(type: AdbServiceType) -> MdnsService? {
        services().first { $0.serviceType == type.rawValue }
    }

    func services(ofType type: AdbServiceType) -> [MdnsService] {
        services().filter { $0.serviceType == type.rawValue }
    }
}
