import SwiftUI

struct InstallView: View {
    var initialIPAURL: URL? = nil
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
                        Text("開始安裝")
                    }
                }
                .disabled(ipaURL == nil || isInstalling || !vpnConnected)
                
                if !progressMessage.isEmpty {
                    HStack {
                        Text(progressMessage)
                            .font(.caption)
                        Spacer()
                        Text("\(progressPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(progressPercent), total: 100)
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
            }
            Task { await checkVPN() }
        }
        .sheet(isPresented: $isPickingIPA) {
            DocumentPicker { url in
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
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
}
