import Foundation
import Network

/// 檢測外置 VPN 隧道是否暢通
public class VPNConnectionChecker {
    public static let shared = VPNConnectionChecker()
    
    /// VPN 網關地址（用戶外置 VPN）
    public var gatewayHost = "10.7.0.1"
    public var gatewayPort: UInt16 = 62078
    
    private init() {}
    
    /// 檢測 VPN 是否連通（TCP 連接到 lockdownd 端口）
    public func checkConnection(timeout: TimeInterval = 10) async -> Bool {
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(gatewayHost),
                port: NWEndpoint.Port(rawValue: gatewayPort)!,
                using: .tcp
            )
            
            let lock = NSLock()
            var resumed = false
            func resume(_ result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: result)
            }
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[VPN] Connected to \(self.gatewayHost):\(self.gatewayPort)")
                    resume(true)
                case .failed(let error):
                    print("[VPN] Failed: \(error)")
                    resume(false)
                case .cancelled:
                    print("[VPN] Cancelled")
                    resume(false)
                case .waiting(let error):
                    print("[VPN] Waiting: \(error)")
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            // 超時
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                print("[VPN] Timeout after \(timeout)s")
                resume(false)
            }
        }
    }
}
