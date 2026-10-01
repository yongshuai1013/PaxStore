import Foundation
import Network

/// 檢測外置 VPN 隧道是否暢通
public class VPNConnectionChecker {
    public static let shared = VPNConnectionChecker()
    
    /// VPN 網關地址（用戶外置 VPN）
    public var gatewayHost = "10.7.0.1"
    public var gatewayPort: UInt16 = 62078
    
    private init() {}
    
    public var lastDiagnostic: String = ""
    
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
                    self.lastDiagnostic = "連接成功"
                    resume(true)
                case .failed(let error):
                    self.lastDiagnostic = "失敗: \(error.localizedDescription)"
                    resume(false)
                case .cancelled:
                    self.lastDiagnostic = "已取消"
                    resume(false)
                case .waiting(let error):
                    self.lastDiagnostic = "等待中: \(error.localizedDescription)"
                case .preparing:
                    self.lastDiagnostic = "準備中..."
                default:
                    break
                }
            }
            
            connection.start(queue: .global())
            
            // 超時
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.lastDiagnostic = "超時 (\(Int(timeout))秒無回應)"
                resume(false)
            }
        }
    }
}
