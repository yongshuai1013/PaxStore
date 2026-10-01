import Foundation
import Network

/// installation_proxy 服務客戶端
public class InstallationProxy {
    private let lockdown: LockdownClient
    private var serviceConnection: NWConnection?
    
    public init(lockdown: LockdownClient) {
        self.lockdown = lockdown
    }
    
    /// 連接到 installation_proxy 服務
    public func connect() async throws {
        let (port, _) = try await lockdown.startService("com.apple.mobile.installation_proxy")
        
        // 建立到服務端口的連接
        // 注意：經 VPN 隧道，服務端口也在同一個主機上
        serviceConnection = NWConnection(
            host: NWEndpoint.Host("10.7.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            serviceConnection?.stateUpdateHandler = { state in
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
            serviceConnection?.start(queue: .global())
        }
    }
    
    /// 安裝 IPA（IPA 需先經 AFC 上傳到 /PublicStaging/）
    public func install(packagePath: String, progress: @escaping (Int) -> Void) async throws {
        guard let connection = serviceConnection else {
            throw LockdownError.notConnected
        }
        
        // 發送 Install 命令
        let command: [String: Any] = [
            "Command": "Install",
            "PackagePath": packagePath,
            "ClientOptions": [
                "CFBundleIdentifier": "PaxStore",
                "CloseOnInvalidate": true
            ] as [String: Any]
        ]
        
        try await sendPlist(command, over: connection)
        
        // 接收進度更新
        while true {
            let response = try await receivePlist(over: connection)
            
            if let status = response["Status"] as? String {
                switch status {
                case "Complete":
                    return
                case "Error":
                    let desc = response["ErrorDescription"] as? String ?? "未知錯誤"
                    throw InstallationError.installFailed(desc)
                default:
                    break
                }
            }
            
            if let percent = response["PercentComplete"] as? Int {
                progress(percent)
            }
        }
    }
    
    private func sendPlist(_ dict: [String: Any], over connection: NWConnection) async throws {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,  // installation_proxy 用 XML
            options: 0
        )
        
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: lengthData + plistData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    private func receivePlist(over connection: NWConnection) async throws -> [String: Any] {
        let lengthData = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LockdownError.incompleteData)
                }
            }
        } as Data
        
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        let plistData = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LockdownError.incompleteData)
                }
            }
        } as Data
        
        guard let dict = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        
        return dict
    }
    
    public func disconnect() {
        serviceConnection?.cancel()
        serviceConnection = nil
    }
}

public enum InstallationError: Error, LocalizedError {
    case installFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .installFailed(let desc): return "安裝失敗: \(desc)"
        }
    }
}
