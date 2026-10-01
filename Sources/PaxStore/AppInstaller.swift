import Foundation

/// App 安裝協調器（經外置 VPN）
public class AppInstaller {
    public static let shared = AppInstaller()
    
    private init() {}
    
    /// 安裝已簽名的 IPA
    public func install(ipaURL: URL, progress: @escaping (String, Int) -> Void) async throws {
        // 1. 檢查 VPN
        progress("檢查 VPN 連線...", 0)
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { throw InstallerError.vpnNotConnected }
        let host = VPNConnectionChecker.shared.gatewayHost
        
        // 2. 找到配對檔
        progress("讀取配對檔...", 5)
        guard let pairingURL = findPairingFile() else { throw InstallerError.noPairingFile }
        
        // 3. 連接 lockdownd（TLS + 握手）
        progress("連接設備...", 10)
        let lockdown = LockdownClient(host: host)
        try await lockdown.connect(pairingFileURL: pairingURL)
        defer { lockdown.disconnect() }
        progress("配對驗證通過", 15)
        
        // 4. 上傳 IPA (經 AFC)
        progress("上傳 IPA...", 20)
        let (afcPort, afcSSL) = try await lockdown.startService("com.apple.afc")
        let afc = AFCClient(host: host)
        try await afc.connect(port: afcPort, useSSL: afcSSL, identity: lockdown.identity)
        defer { afc.disconnect() }
        let remoteName = "PaxStore-\(UUID().uuidString.prefix(8)).ipa"
        let stagedPath = "/PublicStaging/\(remoteName)"
        try await afc.uploadFile(localURL: ipaURL, remotePath: stagedPath) { sent, total in
            let pct = total > 0 ? Int(sent * 60 / total) : 0
            progress("上傳 IPA... \(sent / 1024 / 1024)MB / \(total / 1024 / 1024)MB", 20 + pct)
        }
        progress("上傳完成", 80)
        
        // 5. 經 installation_proxy 安裝
        progress("開始安裝...", 82)
        let proxy = InstallationProxy(lockdown: lockdown, host: host)
        try await proxy.connect()
        defer { proxy.disconnect() }
        try await proxy.install(packagePath: stagedPath) { percent in
            progress("安裝中... \(percent)%", 82 + percent * 18 / 100)
        }
        
        progress("完成", 100)
    }
    
    private func findPairingFile() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PairingFiles")
        let lockdownURL = dir.appendingPathComponent("PairingFile_Lockdown.plist")
        if FileManager.default.fileExists(atPath: lockdownURL.path) {
            return lockdownURL
        }
        // 兼容：找目錄下第一個 plist
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            return files.first(where: { $0.pathExtension == "plist" })
        }
        return nil
    }
}

public enum InstallerError: Error, LocalizedError {
    case vpnNotConnected
    case noPairingFile
    
    public var errorDescription: String? {
        switch self {
        case .vpnNotConnected:
            return "VPN 未連接，請確認外置 VPN 已啟動並加好 10.7.0.1/32 路由"
        case .noPairingFile:
            return "找不到配對檔，請先到配對檔管理導入"
        }
    }
}
