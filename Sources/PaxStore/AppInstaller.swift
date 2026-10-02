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
        // 動態服務端口不一定走 VPN 回環：10.7.0.1 通常只轉發 62078，
        // 先找一個 TCP 真正連得上的地址（127.0.0.1 / Wi-Fi IP 直連）
        guard let afcHost = await VPNConnectionChecker.shared.resolveServiceHost(port: afcPort) else {
            throw InstallerError.serviceUnreachable("AFC", afcPort)
        }
        progress("AFC 服務地址=\(afcHost):\(afcPort) SSL=\(afcSSL)", 20)
        let remoteName = "PaxStore-\(UUID().uuidString.prefix(8)).ipa"
        let stagedPath = "PublicStaging/\(remoteName)"  // 對照 idevice：無前導斜線
        // 連線階段：先按設備要求的 SSL 設置連（TLS 已對照 idevice 加 SNI "Device"）；
        // 若 TLS 握手被對方掐掉（-9806），改試明文。每一步都在 UI 顯示，不是隱藏重試。
        var connectedAFC: AFCClient?
        var connectErrors: [String] = []
        let attempts: [Bool] = afcSSL ? [true, false] : [false]
        for attemptSSL in attempts {
            if !attemptSSL && afcSSL { progress("AFC TLS 被拒，改試明文…", 20) }
            let afc = AFCClient(host: afcHost)
            do {
                try await afc.connect(port: afcPort, useSSL: attemptSSL, identity: attemptSSL ? lockdown.identity : nil)
                connectedAFC = afc
                break
            } catch {
                connectErrors.append((attemptSSL ? "TLS" : "明文") + ":\(error)")
                progress("AFC \(attemptSSL ? "TLS" : "明文")失敗(\(error))", 20)
                afc.disconnect()
            }
        }
        guard let afc = connectedAFC else {
            throw InstallerError.afcFailed(connectErrors.joined(separator: "；"))
        }
        defer { afc.disconnect() }
        // 上傳階段：握手已過，失敗直接報真實錯誤
        try await afc.uploadFile(localURL: ipaURL, remotePath: stagedPath) { sent, total in
            let pct = total > 0 ? Int(sent * 60 / total) : 0
            progress("上傳 IPA... \(sent / 1024 / 1024)MB / \(total / 1024 / 1024)MB", 20 + pct)
        }
        progress("上傳完成", 80)
        
        // 5. 經 installation_proxy 安裝
        progress("開始安裝...", 82)
        let proxy = InstallationProxy(lockdown: lockdown)
        let proxyHost = try await proxy.connect()
        progress("安裝服務地址=\(proxyHost)", 82)
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
    case serviceUnreachable(String, UInt16)
    case afcFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .vpnNotConnected:
            return "VPN 未連接，請確認外置 VPN 已啟動並加好 10.7.0.1/32 路由"
        case .noPairingFile:
            return "找不到配對檔，請先到配對檔管理導入"
        case .serviceUnreachable(let name, let port):
            return "\(name) 服務端口 \(port) 連不上（已試 127.0.0.1、Wi-Fi IP、VPN 地址）"
        case .afcFailed(let desc):
            return "AFC 連線失敗：\(desc)"
        }
    }
}

