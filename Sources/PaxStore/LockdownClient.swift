import Foundation
import Network
import Security

/// Lockdown 協議客戶端（經 VPN 隧道連接設備）
public class LockdownClient {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    
    public init(host: String = "10.7.0.1", port: UInt16 = 62078) {
        self.host = host
        self.port = port
    }
    
    /// 使用配對檔建立 TLS 連接
    public func connect(pairingFileURL: URL) async throws {
        // 讀取配對檔
        guard let plist = NSDictionary(contentsOf: pairingFileURL) as? [String: Any] else {
            throw LockdownError.invalidPairingFile
        }
        
        // 提取證書和私鑰
        // 配對檔包含: DeviceCertificate (PEM), HostCertificate (PEM), HostPrivateKey (PEM), RootCertificate (PEM)
        guard let deviceCertPEM = plist["DeviceCertificate"] as? Data ?? (plist["DeviceCertificate"] as? String)?.data(using: .utf8),
              let hostCertPEM = plist["HostCertificate"] as? Data ?? (plist["HostCertificate"] as? String)?.data(using: .utf8),
              let hostKeyPEM = plist["HostPrivateKey"] as? Data ?? (plist["HostPrivateKey"] as? String)?.data(using: .utf8) else {
            throw LockdownError.missingCredentials
        }
        
        // 建立 TLS 參數（客戶端證書認證）
        let tlsOptions = NWProtocolTLS.Options()
        
        // 這裡需要將 PEM 轉為 SecIdentity
        // 實際實作需要解析 PEM 並創建 SecIdentity
        // 為簡化，先建立基本連接，TLS 細節後續完善
        
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        
        // 等待連接就緒
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection?.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: LockdownError.connectionCancelled)
                default:
                    break
                }
            }
            connection?.start(queue: .global())
        }
    }
    
    /// 發送 plist 消息並接收回應
    public func sendPlist(_ dict: [String: Any]) async throws -> [String: Any] {
        guard let connection = connection else {
            throw LockdownError.notConnected
        }
        
        // 將 dict 轉為 binary plist
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .binary,
            options: 0
        )
        
        // Lockdown 協議：4 字節大端長度 + plist 數據
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        
        // 發送
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: lengthData + plistData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        
        // 接收回應（先讀 4 字節長度）
        let lengthResponse = try await receive(length: 4)
        let responseLength = lengthResponse.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // 讀取 plist 數據
        let plistResponse = try await receive(length: Int(responseLength))
        
        guard let responseDict = try PropertyListSerialization.propertyList(
            from: plistResponse,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        
        return responseDict
    }
    
    private func receive(length: Int) async throws -> Data {
        guard let connection = connection else {
            throw LockdownError.notConnected
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, data.count >= length {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LockdownError.incompleteData)
                }
            }
        }
    }
    
    /// 啟動服務（如 com.apple.mobile.installation_proxy）
    public func startService(_ serviceName: String) async throws -> (port: UInt16, sslEnabled: Bool) {
        let response = try await sendPlist([
            "Label": "PaxStore",
            "Request": "StartService",
            "Service": serviceName
        ])
        
        guard let port = response["Port"] as? UInt16 ?? (response["Port"] as? Int).map({ UInt16($0) }) else {
            throw LockdownError.serviceStartFailed(serviceName)
        }
        
        let sslEnabled = (response["EnableServiceSSL"] as? Bool) ?? false
        return (port, sslEnabled)
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

public enum LockdownError: Error, LocalizedError {
    case invalidPairingFile
    case missingCredentials
    case notConnected
    case connectionCancelled
    case invalidResponse
    case incompleteData
    case serviceStartFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPairingFile: return "配對檔無效"
        case .missingCredentials: return "配對檔缺少證書"
        case .notConnected: return "未連接"
        case .connectionCancelled: return "連接已取消"
        case .invalidResponse: return "回應無效"
        case .incompleteData: return "數據不完整"
        case .serviceStartFailed(let s): return "啟動服務失敗: \(s)"
        }
    }
}
