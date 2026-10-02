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
        // 真機證據：這台設備的 afcd 收到 TLS ClientHello 就掐線（-9806），且該端口隨後不可用；
        // 因此每種方式都用全新的 StartService 端口，明文先試（TLS 會毒化端口）。
        // 若設備要求 SSL 而明文被拒，再換新端口試 TLS。每一步都在 UI 顯示。
        progress("上傳 IPA...", 20)
        let remoteName = "PaxStore-\(UUID().uuidString.prefix(8)).ipa"
        let stagedPath = "PublicStaging/\(remoteName)"  // 對照 idevice：無前導斜線
        var uploadErrors: [String] = []
        var uploaded = false
        // 先明文後 TLS（懷疑 TLS 失敗會污染後續連接）
        for wantSSL in [false, true] {
            let (afcPort, afcSSL) = try await lockdown.startService("com.apple.afc")
            // 用 127.0.0.1：10.7.0.1 的 VPN 只轉發 62078，動態端口過去是黑洞會卡死；
            // 127.0.0.1 有真正的 afcd，TLS -9806 是明確的協議錯誤而非卡死
            let afcHost = "127.0.0.1"
            guard !afcHost.isEmpty else {
                uploadErrors.append("服務端口 \(afcPort) 不可達")
                progress("AFC 服務端口 \(afcPort) 不可達，換新端口重試…", 20)
                continue
            }
            let useSSL = wantSSL && afcSSL
            progress("AFC 服務地址=\(afcHost):\(afcPort) 試\(useSSL ? "TLS" : "明文")…", 20)
            let afc = AFCClient(host: afcHost)
            do {
                try await afc.connect(port: afcPort, useSSL: useSSL, identity: useSSL ? lockdown.identity : nil)
                try await afc.uploadFile(localURL: ipaURL, remotePath: stagedPath) { sent, total in
                    let pct = total > 0 ? Int(sent * 60 / total) : 0
                    progress("上傳 IPA... \(sent / 1024 / 1024)MB / \(total / 1024 / 1024)MB", 20 + pct)
                }
                uploaded = true
                afc.disconnect()
                progress("上傳完成（\(useSSL ? "TLS" : "明文")）", 80)
                break
            } catch {
                uploadErrors.append((useSSL ? "TLS" : "明文") + ":\(error)")
                progress("AFC \(useSSL ? "TLS" : "明文")失敗(\(error))", 20)
                afc.disconnect()
                if !afcSSL { break }  // 設備沒要求 SSL，明文失敗就不用再試 TLS
            }
        }
        guard uploaded else {
            throw InstallerError.afcFailed(uploadErrors.joined(separator: "；"))
        }
        
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

