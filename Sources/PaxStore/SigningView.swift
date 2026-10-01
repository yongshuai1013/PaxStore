import SwiftUI
import SideSign

/// 證書管理頁（最簡版，先保證編譯通過）
struct SigningView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var certificates: [SideSign.X509Certificate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
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
            
            Section(header: Text("CERTIFICATES")) {
                if certificates.isEmpty {
                    Text(isLoading ? "載入中..." : "無")
                } else {
                    ForEach(certificates, id: \.serialNumberHex) { cert in
                        VStack(alignment: .leading) {
                            Text(cert.machineName ?? "Unknown")
                            Text(cert.serialNumberHex)
                                .font(.caption)
                                .foregroundColor(.gray)
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
        .onAppear { loadTeams() }
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
}
