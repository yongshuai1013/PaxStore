import Foundation

/// App 安裝協調器（經外置 VPN）
public class AppInstaller {
    public static let shared = AppInstaller()
    
    private init() {}
    
    /// 安裝已簽名的 IPA
    /// - Parameters:
    ///   - ipaURL: 本地已簽名 IPA 路徑
    ///   - progress: 進度回調 (階段, 百分比)
    public func install(ipaURL: URL, progress: @escaping (String, Int) -> Void) async throws {
        // 1. 檢查 VPN
        progress("檢查 VPN 連線...", 0)
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else {
            throw InstallerError.vpnNotConnected
        }
        
        // 2. 找到配對檔
        progress("讀取配對檔...", 5)
        guard let pairingURL = findPairingFile() else {
            throw InstallerError.noPairingFile
        }
        
        // 3. 連接 lockdownd
        progress("連接設備...", 10)
        let lockdown = LockdownClient()
        try await lockdown.connect(pairingFileURL: pairingURL)
        defer { lockdown.disconnect() }
        
        // 4. 上傳 IPA (經 AFC)
        // TODO: AFC 上傳實作
        progress("上傳 IPA...", 20)
        let stagedPath = "/PublicStaging/\(ipaURL.lastPathComponent)"
        // 暫時拋出未實作，讓用戶知道進度
        throw InstallerError.notImplemented("AFC 上傳尚未實作")
        
        // 5. 安裝
        // let installer = InstallationProxy(lockdown: lockdown)
        // try await installer.connect()
        // try await installer.install(packagePath: stagedPath) { percent in
        //     progress("安裝中...", 20 + percent * 80 / 100)
        // }
        
        // progress("完成", 100)
    }
    
    private func findPairingFile() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("PairingFiles")
        let lockdownURL = dir.appendingPathComponent("PairingFile_Lockdown.plist")
        if FileManager.default.fileExists(atPath: lockdownURL.path) {
            return lockdownURL
        }
        return nil
    }
}

public enum InstallerError: Error, LocalizedError {
    case vpnNotConnected
    case noPairingFile
    case notImplemented(String)
    
    public var errorDescription: String? {
        switch self {
        case .vpnNotConnected:
            return "VPN 未連接，請確認外置 VPN 已啟動 (10.7.0.1:62078)"
        case .noPairingFile:
            return "找不到配對檔，請先到配對檔管理導入"
        case .notImplemented(let what):
            return "\(what)"
        }
    }
}
