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
        
        // 3. 上傳 IPA (經 Rust idevice-ffi 的 AFC；內部自建 lockdownd，不與 Swift 重疊)
        progress("上傳 IPA... (Swift/127.0.0.1)", 20)
        let remoteName = "PaxStore-\(UUID().uuidString.prefix(8)).ipa"
        let stagedPath = "PublicStaging/\(remoteName)"
        let installPath = "/PublicStaging/\(remoteName)"
        // 先拿 AFC 端口（經 10.7.0.1 lockdownd），再斷開
        let tmpLockdown = LockdownClient(host: host)
        try await tmpLockdown.connect(pairingFileURL: pairingURL)
        let (afcPort, _) = try await tmpLockdown.startService("com.apple.afc")
        guard let afcIdentity = tmpLockdown.identity else {
            tmpLockdown.disconnect()
            throw InstallerError.afcFailed("無法取得配對 identity")
        }
        tmpLockdown.disconnect()
        // AFC 走 127.0.0.1（VPN 只轉發 10.7.0.1:62078，動態端口不轉）
        let afc = AFCClient(host: "127.0.0.1")
        do {
            try await afc.connect(port: afcPort, useSSL: true, identity: afcIdentity)
            try await afc.uploadFile(localURL: ipaURL, remotePath: stagedPath) { sent, total in
                let pct = total > 0 ? Int(sent * 60 / total) : 0
                progress("上傳 IPA... \(sent / 1024 / 1024)MB / \(total / 1024 / 1024)MB", 20 + pct)
            }
            afc.disconnect()
            progress("上傳完成", 80)
        } catch {
            afc.disconnect()
            throw InstallerError.afcFailed("Swift AFC: \(error)")
        }
        }
        
        // 4. 連接 lockdownd（上傳完成後再建，供 installation_proxy 用）
        progress("連接設備...", 81)
        let lockdown = LockdownClient(host: host)
        try await lockdown.connect(pairingFileURL: pairingURL)
        defer { lockdown.disconnect() }
        progress("配對驗證通過", 82)

        // 5. 經 installation_proxy 安裝
        progress("開始安裝...", 82)
        let proxy = InstallationProxy(lockdown: lockdown)
        let proxyHost = try await proxy.connect()
        progress("安裝服務地址=\(proxyHost)", 82)
        defer { proxy.disconnect() }
        try await proxy.install(packagePath: installPath) { percent in
            progress("安裝中... \(percent)%", 82 + percent * 18 / 100)
        }
        
        progress("完成", 100)
    }
    

    /// 診斷 AFC：對每個候選 host 試 TLS 和明文，返回報告（不傳文件，只建連接）
    public func diagnoseAFC() async -> String {
        var lines: [String] = []
        lines.append("AFC 引擎: SwiftNIO/BoringSSL (build be849008+)")
        let vpnOK = await VPNConnectionChecker.shared.checkConnection()
        guard vpnOK else { return "VPN 未連接" }
        let gatewayHost = VPNConnectionChecker.shared.gatewayHost
        guard let pairingURL = findPairingFile() else { return "找不到配對檔" }
        let lockdown = LockdownClient(host: gatewayHost)
        do {
            try await lockdown.connect(pairingFileURL: pairingURL)
        } catch {
            return "lockdownd 連接失敗: \(error)"
        }
        defer { lockdown.disconnect() }
        lines.append("lockdownd OK (\(gatewayHost):62078)")
        var hosts = ["127.0.0.1"]
        if let wifiIP = VPNConnectionChecker.shared.discoverWiFiIP(), wifiIP != "127.0.0.1", !hosts.contains(wifiIP) {
            hosts.append(wifiIP)
        }
        if gatewayHost != "127.0.0.1", !hosts.contains(gatewayHost) {
            hosts.append(gatewayHost)
        }
        for host in hosts {
            lines.append("— \(host) —")
            for wantSSL in [true, false] {
                let label = wantSSL ? "TLS" : "明文"
                do {
                    let (port, sslEnabled) = try await lockdown.startService("com.apple.afc")
                    let useSSL = wantSSL && sslEnabled
                    let actualLabel = useSSL ? "TLS" : "明文"
                    let afc = AFCClient(host: host)
                    do {
                        try await afc.connect(port: port, useSSL: useSSL, identity: useSSL ? lockdown.identity : nil)
                        afc.disconnect()
                        lines.append("  \(actualLabel) \(host):\(port): 連接成功")
                    } catch {
                        lines.append("  \(actualLabel) \(host):\(port): \(error)")
                    }
                } catch {
                    lines.append("  \(label) StartService 失敗: \(error)")
                }
            }
        }
        return lines.joined(separator: "\n")
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

