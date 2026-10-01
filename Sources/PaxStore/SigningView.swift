import SwiftUI
import SideSign

/// 證書管理頁（仿 SideStore）
struct SigningView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeam: SideSign.Team?
    @State private var certificates: [SideSign.X509Certificate] = []
    @State private var activeKeyStore: SideSign.KeyStore?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var certToRevoke: SideSign.X509Certificate?
    @State private var showRevokeAlert = false
    
    var body: some View {
        Form {
            // Team 選擇
            Section(header: Text("TEAM")) {
                if teams.isEmpty && isLoading {
                    ProgressView("載入中...")
                } else {
                    Picker("Team", selection: $selectedTeam) {
                        ForEach(teams, id: \.identifier) { team in
                            Text(team.name).tag(team as SideSign.Team?)
                        }
                    }
                    .onChange(of: selectedTeam) { newTeam in
                        if let team = newTeam {
                            loadCertificates(for: team)
                        }
                    }
                }
            }
            
            // 激活的本地證書
            if let keyStore = activeKeyStore {
                Section(header: Text("ACTIVE LOCAL CERTIFICATE")) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Active Signing Certificate")
                                    .font(.headline)
                                Button(action: {
                                    UIPasteboard.general.string = keyStore.certificate.serialNumberHex
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.gray)
                                }
                            }
                            Text("SN:")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(keyStore.certificate.serialNumberHex)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    Button("Deactivate Locally") {
                        PaxSigningService.shared.clearActiveCertificate()
                        activeKeyStore = nil
                    }
                    .foregroundColor(.red)
                }
            }
            
            // 證書列表
            if let team = selectedTeam {
                Section(header: HStack {
                    Text("CERTIFICATES \(certificates.count)")
                    Spacer()
                    // 佔位按鈕（排序/視圖切換，暫不實現）
                }) {
                    if certificates.isEmpty && !isLoading {
                        Text("暫無證書")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(certificates, id: \.serialNumberHex) { cert in
                            CertificateRow(
                                certificate: cert,
                                hasPrivateKey: activeKeyStore?.certificate.serialNumberHex == cert.serialNumberHex,
                                onRevoke: {
                                    certToRevoke = cert
                                    showRevokeAlert = true
                                }
                            )
                        }
                    }
                    
                    Button("創建新證書") {
                        createCertificate(for: team)
                    }
                    .disabled(isLoading)
                }
                
                Section(footer: Text("Suffix (R) indicates the certificate is revoked. Green check means the private key is available locally.")) {
                    EmptyView()
                }
            }
            
            if let error = errorMessage {
                Section(header: Text("錯誤")) {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("證書管理")
        .onAppear {
            activeKeyStore = PaxSigningService.shared.loadActiveCertificate()
            loadTeams()
        }
        .alert("撤銷證書？", isPresented: $showRevokeAlert) {
            Button("撤銷", role: .destructive) {
                if let cert = certToRevoke, let team = selectedTeam {
                    revokeCertificate(cert, for: team)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let cert = certToRevoke {
                Text("確定要撤銷 \(cert[.machineName] ?? cert.serialNumberHex) 嗎？此操作不可恢復。")
            }
        }
    }
    
    private func loadTeams() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    self.teams = result
                    self.isLoading = false
                    if selectedTeam == nil, let first = result.first {
                        selectedTeam = first
                        loadCertificates(for: first)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadCertificates(for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchCertificates(for: team)
                await MainActor.run {
                    self.certificates = result
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func createCertificate(for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let keyStore = try await PaxSigningService.shared.createCertificate(for: team)
                await MainActor.run {
                    self.activeKeyStore = keyStore
                    self.isLoading = false
                }
                loadCertificates(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func revokeCertificate(_ cert: SideSign.X509Certificate, for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await PaxSigningService.shared.revokeCertificate(cert, for: team)
                await MainActor.run {
                    self.isLoading = false
                }
                // 如果撤銷的是激活證書，清除本地
                if activeKeyStore?.certificate.serialNumberHex == cert.serialNumberHex {
                    PaxSigningService.shared.clearActiveCertificate()
                    await MainActor.run {
                        self.activeKeyStore = nil
                    }
                }
                loadCertificates(for: team)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Certificate Row

struct CertificateRow: View {
    let certificate: SideSign.X509Certificate
    let hasPrivateKey: Bool
    let onRevoke: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(certificate[.machineName] ?? certificate[.displayName] ?? "Unknown")
                        .font(.headline)
                    Group {
                        Text("Serial: \(certificate.serialNumberHex)")
                        Text("ID: \(certificate[.identifier] ?? "-")")
                        Text("Type: \(certificate[.certificateTypeName] ?? certificate[.certificateType] ?? "-")")
                        if let notBefore = certificate.notBefore, let notAfter = certificate.notAfter {
                            Text("Validity: \(formatDate(notBefore)) - \(formatDate(notAfter))")
                        }
                        Text("Requester: \(certificate[.requesterEmail] ?? "-")")
                        if let firstName = certificate[.requesterFirstName], let lastName = certificate[.requesterLastName] {
                            Text("Created By: \(firstName)\(lastName)")
                        } else if let owner = certificate[.ownerName] {
                            Text("Created By: \(owner)")
                        }
                        Text("Keys: \(hasPrivateKey ? "public + private" : "public")")
                    }
                    .font(.caption)
                    .foregroundColor(.gray)
                }
                
                Spacer()
                
                // 狀態圖標：有私鑰=綠勾，無私鑰=紅叉
                Image(systemName: hasPrivateKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(hasPrivateKey ? .green : .red)
                    .font(.title2)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !hasPrivateKey {
                Button("撤銷證書", role: .destructive) {
                    onRevoke()
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/M/d"
        return formatter.string(from: date)
    }
}

