#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Detects Tailscale network interfaces on the local machine.
/// Tailscale uses the CGNAT range 100.64.0.0/10 (100.64.0.0 – 100.127.255.255).
enum TailscaleDetector {

    /// Returns the first Tailscale IPv4 address found, or nil.
    static func detectTailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var result: String?
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let addr = current {
            let sa = addr.pointee.ifa_addr
            if let sa, sa.pointee.sa_family == UInt8(AF_INET) {
                // IPv4
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if isTailscaleIP(ip) {
                        result = ip
                        break
                    }
                }
            }
            current = addr.pointee.ifa_next
        }

        return result
    }

    /// Check if an IP is in the Tailscale CGNAT range 100.64.0.0/10.
    static func isTailscaleIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        // 100.64.0.0/10 means second octet: 64-127
        return parts[1] >= 64 && parts[1] <= 127
    }

    /// Whether Tailscale appears to be available on this machine.
    static var isAvailable: Bool {
        detectTailscaleIP() != nil
    }
}
