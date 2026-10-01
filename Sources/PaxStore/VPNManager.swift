import Foundation
import NetworkExtension

/// 內置 WireGuard VPN 管理器
public class VPNManager {
    public static let shared = VPNManager()
    
    private var tunnelManager: NETunnelProviderManager?
    private let tunnelBundleID = "com.paxstore.app.vpn"
    
    private init() {}
    
    /// 載入或創建 VPN 配置
    public func loadManager() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        tunnelManager = managers.first { $0.protocolConfiguration?.providerBundleIdentifier == tunnelBundleID }
        
        if tunnelManager == nil {
            tunnelManager = NETunnelProviderManager()
            tunnelManager?.localizedDescription = "PaxStore VPN"
            
            let protocolConfig = NETunnelProviderProtocol()
            protocolConfig.providerBundleIdentifier = tunnelBundleID
            protocolConfig.serverAddress = "10.7.0.1"
            
            // WireGuard 配置（預設值，用戶可在設置中修改）
            // 格式：WireGuard 配置文件內容
            let wgConfig = """
            [Interface]
            PrivateKey = <自動生成>
            Address = 10.7.0.10/24
            
            [Peer]
            PublicKey = <設備公鑰>
            Endpoint = 127.0.0.1:51820
            AllowedIPs = 10.7.0.1/32
            PersistentKeepalive = 25
            """
            protocolConfig.providerConfiguration = ["wgConfig": wgConfig]
            
            tunnelManager?.protocolConfiguration = protocolConfig
            tunnelManager?.isEnabled = true
            
            try await tunnelManager?.saveToPreferences()
            try await tunnelManager?.loadFromPreferences()
        }
    }
    
    /// 啟動 VPN
    public func connect() async throws {
        try await loadManager()
        guard let manager = tunnelManager else {
            throw VPNError.managerNotFound
        }
        
        if manager.connection.status == .connected || manager.connection.status == .connecting {
            return
        }
        
        try manager.connection.startVPNTunnel()
    }
    
    /// 斷開 VPN
    public func disconnect() {
        tunnelManager?.connection.stopVPNTunnel()
    }
    
    /// 獲取連接狀態
    public var status: NEVPNStatus {
        return tunnelManager?.connection.status ?? .invalid
    }
    
    /// 是否已連接
    public var isConnected: Bool {
        return status == .connected
    }
}

public enum VPNError: Error, LocalizedError {
    case managerNotFound
    
    public var errorDescription: String? {
        switch self {
        case .managerNotFound:
            return "VPN 管理器未找到"
        }
    }
}
