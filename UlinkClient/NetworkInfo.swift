import Foundation

enum NetworkInfo {

    /// Best-effort Wi-Fi (en0/en1) IPv4 address, so the PC knows where to connect.
    static func wifiAddress() -> String? {
        var wifi: String?
        var any: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if name == "en0" || name == "en1" {
                        wifi = ip
                    } else if name != "lo0", any == nil {
                        any = ip
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return wifi ?? any
    }
}
