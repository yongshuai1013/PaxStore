import SwiftUI
import ZIPFoundation

struct InstallView: View {
    var initialIPAURL: URL? = nil
    var plistMode: Bool = false
    @State private var vpnConnected = false
    @State private var isCheckingVPN = false
    @State private var vpnHost = "10.7.0.1"
    @State private var vpnPort = "62078"
    @State private var vpnDiagnostic = ""
    @State private var ipaURL: URL?
    @State private var isPickingIPA = false
    @State private var isInstalling = false
    @State private var progressMessage = ""
    @State private var progressPercent = 0
    @State private var errorMessage: String?
    @State private var isDiagnosing = false
    @State private var afcDiagnostic = ""
    @State private var showingLog = false
    @State private var logContent = ""
    @StateObject private var updateChecker = UpdateChecker()
    @State private var useExternalPlist = false
    @State private var debugPlistURL = ""
    @State private var debugIpaURL = ""
    
    var body: some View {
        List {
            // 外置 VPN 狀態 (WireGuard / LocalDevVPN)
            Section(header: Text("VPN 連線")) {
                HStack {
                    Text("外置 VPN")
                    Spacer()
                    if isCheckingVPN {
                        ProgressView()
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(vpnConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(vpnConnected ? "已連接" : "未連接")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((vpnConnected ? Color.green : Color.red).opacity(0.15))
                        .cornerRadius(12)
                    }
                }
                HStack {
                    Text("主機")
                    TextField("10.7.0.1", text: $vpnHost)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text("端口")
                    TextField("62078", text: $vpnPort)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.numberPad)
                }
                Button("檢測連線") {
                    Task { await checkVPN() }
                }
                .disabled(isCheckingVPN)
                if !vpnDiagnostic.isEmpty {
                    Text(vpnDiagnostic)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Text("先在 WireGuard / LocalDevVPN 中開啟隧道，再點檢測連線")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            // AFC 診斷
            Section(header: Text("AFC 診斷")) {
                Button(action: {
                    Task { await diagnoseAFC() }
                }) {
                    if isDiagnosing {
                        HStack {
                            ProgressView()
                            Text("診斷中...")
                        }
                    } else {
                        Text("診斷 AFC 連線")
                    }
                }
                .disabled(isDiagnosing || !vpnConnected)
                if !afcDiagnostic.isEmpty {
                    Text(afcDiagnostic)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Button("查看 AFC 日誌") {
                    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let url = docs.appendingPathComponent("afc_debug.log")
                        logContent = (try? String(contentsOf: url)) ?? "無日誌"
                    }
                    showingLog = true
                }
                Button("清除日誌") {
                    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let url = docs.appendingPathComponent("afc_debug.log")
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            
            Section(header: Text("更新")) {
                Button("檢查更新") {
                    updateChecker.check()
                }
                .disabled(updateChecker.isChecking)
                if !updateChecker.statusMessage.isEmpty {
                    Text(updateChecker.statusMessage)
                        .font(.caption)
                        .foregroundColor(updateChecker.updateAvailable ? .green : .secondary)
                }
            }
            
            // 選擇 IPA
            Section(header: Text("1. 選擇已簽名 IPA")) {
                if let url = ipaURL {
                    Text(url.lastPathComponent)
                } else {
                    Text("尚未選擇")
                        .foregroundColor(.gray)
                }
                Button("選擇 IPA 文件") {
                    isPickingIPA = true
                }
            }
            
            // 安裝
            Section(header: Text("2. 安裝")) {
                Button(action: {
                    Task { await startInstall() }
                }) {
                    if isInstalling {
                        HStack {
                            ProgressView()
                            Text("安裝中...")
                        }
                    } else {
                        Text("開始安裝 (AFC)")
                    }
                }
                .disabled(ipaURL == nil || isInstalling || !vpnConnected)

                Picker("plist 模式", selection: $useExternalPlist) {
                    Text("本地").tag(false)
                    Text("線上 (iOS 18+)").tag(true)
                }
                .pickerStyle(.segmented)

                Button(action: {
                    Task { await startPlistInstall() }
                }) {
                    Text("用 plist 安裝 (免 VPN)")
                }
                .disabled(ipaURL == nil || isInstalling)

                if !debugPlistURL.isEmpty {
                    Text("Plist: \(debugPlistURL)").font(.caption).textSelection(.enabled)
                    Text("IPA: \(debugIpaURL)").font(.caption).textSelection(.enabled)
                }

                if !progressMessage.isEmpty {
                    HStack {
                        Text(progressMessage)
                            .font(.caption)
                        Spacer()
                        Text("\(progressPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                    }

                }
            }
            
            if let err = errorMessage {
                Section {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("安裝 App")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let initial = initialIPAURL {
                ipaURL = initial
                if plistMode {
                    Task { await startPlistInstall() }
                }
            }
            Task { await checkVPN() }
        }
        .sheet(isPresented: $isPickingIPA) {
            DocumentPicker { url in
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let dest = docs.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    try FileManager.default.copyItem(at: url, to: dest)
                    url.stopAccessingSecurityScopedResource()
                    ipaURL = dest
                } catch {
                    errorMessage = "複製文件失敗: \(error.localizedDescription)"
                }
                isPickingIPA = false
            } onCancel: {
                isPickingIPA = false
            }
        }
        .sheet(isPresented: $showingLog) {
            NavigationView {
                ScrollView {
                    Text(logContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .navigationTitle("AFC 日誌")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button("關閉") { showingLog = false })
            }
        }
    }
    
    private func checkVPN() async {
        isCheckingVPN = true
        vpnDiagnostic = ""
        VPNConnectionChecker.shared.gatewayHost = vpnHost
        VPNConnectionChecker.shared.gatewayPort = UInt16(vpnPort) ?? 62078
        vpnConnected = await VPNConnectionChecker.shared.checkConnection()
        vpnHost = VPNConnectionChecker.shared.gatewayHost
        vpnDiagnostic = VPNConnectionChecker.shared.lastDiagnostic
        isCheckingVPN = false
    }
    
    private func diagnoseAFC() async {
        isDiagnosing = true
        afcDiagnostic = ""
        let report = await AppInstaller.shared.diagnoseAFC()
        DispatchQueue.main.async {
            self.afcDiagnostic = report
            self.isDiagnosing = false
        }
    }
    
    private func startInstall() async {
        guard let ipaURL = ipaURL else { return }
        isInstalling = true
        errorMessage = nil
        progressMessage = ""
        progressPercent = 0
        
        do {
            try await AppInstaller.shared.install(ipaURL: ipaURL) { message, percent in
                DispatchQueue.main.async {
                    self.progressMessage = message
                    self.progressPercent = percent
                }
            }
            progressMessage = "安裝完成"
            progressPercent = 100
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isInstalling = false
    }

    private func startPlistInstall() async {
        guard let ipaURL = ipaURL else { return }
        isInstalling = true
        errorMessage = nil
        progressMessage = "正在啟動本地服務..."
        defer { isInstalling = false }

        do {
            let info = try extractAppInfo(from: ipaURL)
            let plistURL = try PlistInstaller.shared.start(
                ipaURL: ipaURL,
                bundleId: info.bundleId,
                appName: info.name,
                version: info.version
            )
            let trigger: URL?
            if useExternalPlist {
                progressMessage = "正在生成線上 plist..."
                trigger = PlistInstaller.shared.installTriggerURLExternal(
                    bundleId: info.bundleId, appName: info.name, version: info.version
                )
            } else {
                trigger = PlistInstaller.shared.installTriggerURL(plistURL: plistURL)
            }
            guard let trigger = trigger else {
                throw PlistError.serverFailed("無法構造安裝鏈接")
            }
            progressMessage = "正在打開系統安裝..."
            debugPlistURL = useExternalPlist ? (PlistInstaller.shared.externalPlistURL(bundleId: info.bundleId, appName: info.name, version: info.version)?.absoluteString ?? "") : plistURL.absoluteString
            debugIpaURL = PlistInstaller.shared.ipaURLString() ?? ""
            AppLogger.shared.log("InstallView: itms URL=\(trigger.absoluteString)")
            await UIApplication.shared.open(trigger)
            AppLogger.shared.log("InstallView: 已打開 itms-services")
            progressMessage = "已發起安裝，請在主屏幕查看進度（服務保持運行）"
        } catch {
            AppLogger.shared.log("InstallView: 錯誤 \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            progressMessage = ""
        }
    }

    private func extractAppInfo(from ipaURL: URL) throws -> (bundleId: String, name: String, version: String) {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw PlistError.serverFailed("無法打開 IPA")
        }
        guard let entry = archive.first(where: { $0.path.hasSuffix(".app/Info.plist") }) else {
            throw PlistError.serverFailed("IPA 裡找不到 Info.plist")
        }
        var data = Data()
        _ = try archive.extract(entry, consumer: { data.append($0) })
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            throw PlistError.serverFailed("無法讀取 IPA 的 Info.plist")
        }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? bundleId
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
        return (bundleId, name, version)
    }
}
