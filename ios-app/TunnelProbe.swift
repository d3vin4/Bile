import Foundation
import Darwin

/// Actively checks whether the loopback VPN really carries traffic to the
/// device by dialling the RSD port (49152) and lockdownd (62078) — the two
/// ports the AirLift pipeline needs.
enum TunnelProbe {

    struct Result: Identifiable {
        let id = UUID()
        let host: String
        let rsd: Bool
        let lockdown: Bool
        var summary: String {
            if rsd && lockdown { return "RSD + lockdown reachable ✅" }
            if rsd { return "RSD reachable (lockdown closed)" }
            if lockdown { return "lockdown reachable (RSD closed) — connect the VPN app" }
            return "not reachable ❌"
        }
        var ok: Bool { rsd || lockdown }
    }

    static let rsdPort: UInt16 = 49152
    static let lockdownPort: UInt16 = 62078

    /// Candidate hosts: whatever the user typed, plus the interfaces plus the
    /// well-known loopback-VPN gateways.
    static func candidates(userHost: String) -> [String] {
        var hosts: [String] = []
        let typed = NetworkStatus.host(userHost)
        if !typed.isEmpty { hosts.append(typed) }
        for ip in NetworkStatus.tunnelHostCandidates() where !hosts.contains(ip) {
            hosts.append(ip)
        }
        for fallback in ["10.7.0.1", "10.7.0.2", "10.7.0.3", "10.0.0.1", "172.16.0.1"]
        where !hosts.contains(fallback) {
            hosts.append(fallback)
        }
        return Array(hosts.prefix(8))
    }

    static func probe(hosts: [String], timeout: TimeInterval = 1.5) -> [Result] {
        hosts.map { host in
            Result(
                host: host,
                rsd: tcpReachable(host: host, port: rsdPort, timeout: timeout),
                lockdown: tcpReachable(host: host, port: lockdownPort, timeout: timeout)
            )
        }
    }

    static func best(hosts: [String]) -> String? {
        probe(hosts: hosts).first(where: { $0.ok })?.host
    }

    /// Blocking connect on a background thread with a bounded wait. The socket
    /// is closed by the worker when the kernel gives up.
    static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        guard NetworkStatus.isIPv4(host) else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        var reached = false
        DispatchQueue.global(qos: .userInitiated).async {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
                semaphore.signal()
                return
            }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                semaphore.signal()
                return
            }
            defer { close(fd) }
            let status = withUnsafePointer(to: addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            reached = (status == 0)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return false
        }
        return reached
    }
}
