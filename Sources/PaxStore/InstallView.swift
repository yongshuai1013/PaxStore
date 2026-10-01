import SwiftUI

struct InstallView: View {
    var initialIPAURL: URL? = nil
    @State private var vpnConnected = false
    @State private var vpnDiagnostic = ""
    @State private var ipaURL: URL?
    @State private var isPickingIPA = false
    @State private var isInstalling = false
    @State private var progressMessage = ""
    @State private var progressPercent = 0
    @State private var errorMessage: String?
    
    var body: some View {
        List {
            // 內置 VPN 狀態
            Section(header: Text("內置 VPN")) {
                HStack {
                    Text("PaxStore VPN")
                    Spacer()
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
                if vpnConnected {
                    Button("斷開 VPN") {
                        Task { await disconnectVPN() }
                    }
                    .foregroundColor(.red)
                } else {
                    Button("連接 VPN") {
                        Task { await connectVPN() }
                    }
                }
                if !vpnDiagnostic.isEmpty {
                    Text(vpnDiagnostic)
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
                    Text(progressMessage)
                        .font(.caption)
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
    
    private func connectVPN() async {
        vpnDiagnostic = "正在連接..."
        do {
            try await VPNManager.shared.connect()
            // 等待連接建立
            try await Task.sleep(nanoseconds: 2_000_000_000)
            vpnConnected = VPNManager.shared.isConnected
            vpnDiagnostic = vpnConnected ? "VPN 已連接" : "連接中，請稍候..."
        } catch {
            vpnDiagnostic = "連接失敗: \(error.localizedDescription)"
        }
    }
    
    private func disconnectVPN() async {
        VPNManager.shared.disconnect()
        vpnConnected = false
        vpnDiagnostic = "已斷開"
    }
    
    private func checkVPN() async {
        vpnConnected = VPNManager.shared.isConnected
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
