import Foundation
import Network
import Darwin

/// 檢測外置 VPN 隧道是否暢通
/// 策略仿 SideStore minimuxer：掃描 utun 接口，自動發現隧道對端 IP，並行 TCP 探測
public class VPNConnectionChecker {
    public static let shared = VPNConnectionChecker()

    /// VPN 網關地址（手動輸入的 fallback；自動發現成功後會更新為實際可用的地址）
    public var gatewayHost = "10.7.0.1"
    public var gatewayPort: UInt16 = 62078

    public var lastDiagnostic: String = ""

    private init() {}

    public struct TunnelInfo {
        public let ifName: String
        public let localIP: String
        public let peerIP: String   // 點對點對端地址；非點對點時為空
        public let netmask: String
    }

    private func ipv4String(_ sa: UnsafePointer<sockaddr>) -> String? {
        var copy = sa.pointee
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(&copy, socklen_t(copy.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(validatingUTF8: buf)
    }

    private func ipv4Raw(_ ip: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
        return a.s_addr.bigEndian
    }

    private func rawToIPv4(_ raw: UInt32) -> String? {
        var addr = in_addr(s_addr: raw.bigEndian)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }

    /// 掃描所有啟用中的 utun 接口
    public func discoverTunnels() -> [TunnelInfo] {
        var result: [TunnelInfo] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let e = p.pointee
            defer { cursor = e.ifa_next }
            guard let namePtr = e.ifa_name else { continue }
            let name = String(cString: namePtr)
            guard name.lowercased().hasPrefix("utun") else { continue }
            let flags = Int32(e.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard let addrPtr = e.ifa_addr, addrPtr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard let localIP = ipv4String(addrPtr) else { continue }
            if result.contains(where: { $0.ifName == name }) { continue }

            var peerIP = ""
            if (flags & IFF_POINTOPOINT) != 0,
               let dstPtr = e.ifa_dstaddr,
               let dst = ipv4String(dstPtr) {
                peerIP = dst
            }
            var mask = ""
            if let maskPtr = e.ifa_netmask, let m = ipv4String(maskPtr) {
                mask = m
            }
            result.append(TunnelInfo(ifName: name, localIP: localIP, peerIP: peerIP, netmask: mask))
        }
        return result.sorted { $0.ifName < $1.ifName }
    }

    private func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            guard let p = NWEndpoint.Port(rawValue: port) else {
                cont.resume(returning: false)
                return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let lock = NSLock()
            var done = false
            func finish(_ r: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// 自動發現隧道對端並並行探測；成功時 gatewayHost 更新為實際可用的地址
    public func checkConnection(timeout: TimeInterval = 5) async -> Bool {
        let tunnels = discoverTunnels()

        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ ip: String) {
            let t = ip.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !seen.contains(t),
                  t != "0.0.0.0",
                  !t.hasPrefix("127."),
                  !t.hasPrefix("224."),
                  !t.hasPrefix("239.") else { return }
            seen.insert(t)
            candidates.append(t)
        }

        // 候選 1：點對點對端地址（LocalDevVPN 這類 /32 隧道）
        for t in tunnels { add(t.peerIP) }
        // 候選 2：接口所在子網的 .1（WireGuard App 那種 /24 配置，設備端常用 .1）
        for t in tunnels {
            if let localRaw = ipv4Raw(t.localIP), let maskRaw = ipv4Raw(t.netmask),
               let first = rawToIPv4((localRaw & maskRaw) + 1) {
                add(first)
            }
        }
        // 候選 3：手動輸入的地址
        add(gatewayHost)

        // 排除接口自己的地址
        let localIPs = Set(tunnels.map { $0.localIP })
        candidates.removeAll { localIPs.contains($0) }

        var diag: String
        if tunnels.isEmpty {
            diag = "未發現啟用的 utun 接口（VPN 隧道可能沒開）。"
        } else {
            diag = tunnels.map {
                "\($0.ifName)(本端\($0.localIP)/\($0.netmask.isEmpty ? "?" : $0.netmask) 對端\($0.peerIP.isEmpty ? "無" : $0.peerIP))"
            }.joined(separator: " ")
        }
        if candidates.isEmpty {
            lastDiagnostic = diag + " 無候選地址可探測。"
            return false
        }
        diag += " 探測 " + candidates.map { "\($0):\(gatewayPort)" }.joined(separator: ", ")

        var winner: String?
        await withTaskGroup(of: (String, Bool).self) { group in
            for c in candidates {
                group.addTask { (c, await self.probe(host: c, port: self.gatewayPort, timeout: timeout)) }
            }
            for await (ip, ok) in group {
                if ok {
                    winner = ip
                    group.cancelAll()
                    break
                }
            }
        }

        if let ip = winner {
            gatewayHost = ip
            lastDiagnostic = diag + " → \(ip) 連通"
            return true
        } else {
            lastDiagnostic = diag + " → 全部無回應"
            return false
        }
    }
}
