import SwiftUI
import SideSign

/// 證書管理頁（最簡版，先保證編譯通過）
struct SigningView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var certificates: [SideSign.X509Certificate] = []
    @State private var activeCertSerial: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var certToRevoke: SideSign.X509Certificate?
    @State private var showRevokeAlert = false
    
    var body: some View {
        List {
            Section(header: Text("TEAM")) {
                if teams.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    ForEach(teams, id: \.identifier) { team in
                        Button(team.name) {
                            loadCertificates(for: team)
                        }
                    }
                }
            }
            
            if let serial = activeCertSerial {
                Section(header: Text("ACTIVE LOCAL CERTIFICATE")) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text("Active Signing Certificate")
                                .font(.headline)
                            Text("SN: \(serial)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    Button("Deactivate Locally") {
                        PaxSigningService.shared.clearActiveCertificate()
                        activeCertSerial = nil
                    }
                    .foregroundColor(.red)
                }
            }
            
            Section(header: Text("CERTIFICATES")) {
                Button("創建新證書") {
                    createCertificate()
                }
                .disabled(isLoading)
                if certificates.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    ForEach(certificates, id: \.serialNumberHex) { cert in
                        let hasKey = (cert.serialNumberHex == activeCertSerial)
                        NavigationLink(destination: CertificateDetailView(cert: cert, hasPrivateKey: hasKey)) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cert.machineName ?? "Unknown")
                                    Text(cert.serialNumberHex)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Image(systemName: hasKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(hasKey ? .green : .red)
                            }
                        }
                        .contextMenu {
                            Button("撤銷證書", role: .destructive) {
                                certToRevoke = cert
                                showRevokeAlert = true
                            }
                        }
                    }
                }
            }
            
            if let error = errorMessage {
                Section(header: Text("錯誤")) {
                    Text(error).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("證書管理")
        .onAppear {
            activeCertSerial = PaxSigningService.shared.loadActiveCertificateSerial()
            loadTeams()
        }
        .alert("撤銷證書？", isPresented: $showRevokeAlert) {
            Button("撤銷", role: .destructive) {
                if let cert = certToRevoke, let team = teams.first {
                    revokeCertificate(cert, for: team)
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            if let cert = certToRevoke {
                Text("確定要撤銷 \(cert.machineName ?? cert.serialNumberHex) 嗎？此操作不可恢復。")
            }
        }
    }
    
    private func loadTeams() {
        isLoading = true
        Task {
            do {
                let result = try await PaxSigningService.shared.fetchTeams()
                await MainActor.run {
                    self.teams = result
                    self.isLoading = false
                    if let first = result.first {
                        self.loadCertificates(for: first)
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
    
    private func revokeCertificate(_ cert: SideSign.X509Certificate, for team: SideSign.Team) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await PaxSigningService.shared.revokeCertificate(cert, for: team)
                let wasActive = (cert.serialNumberHex == activeCertSerial)
                await MainActor.run {
                    self.isLoading = false
                    if wasActive {
                        PaxSigningService.shared.clearActiveCertificate()
                        self.activeCertSerial = nil
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
    
    private func createCertificate() {
        guard let team = teams.first else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let keyStore = try await PaxSigningService.shared.createCertificate(for: team)
                await MainActor.run {
                    self.activeCertSerial = keyStore.certificate.serialNumberHex
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
}
