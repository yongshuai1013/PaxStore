import SwiftUI
import SideSign

/// 簽名管理頁：Team、證書列表
struct SigningView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeam: SideSign.Team?
    @State private var certificates: [SideSign.X509Certificate] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        Form {
            Section(header: Text("Team")) {
                if isLoading && teams.isEmpty {
                    ProgressView("載入中...")
                } else {
                    ForEach(teams, id: \.identifier) { team in
                        Button(action: {
                            selectedTeam = team
                            loadCertificates(for: team)
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(team.name)
                                        .foregroundColor(.primary)
                                    Text(team.identifier)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                if selectedTeam?.identifier == team.identifier {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                
                Button("刷新 Teams") {
                    loadTeams()
                }
                .disabled(isLoading)
            }
            
            if let team = selectedTeam {
                Section(header: Text("證書 (\(team.name))")) {
                    if certificates.isEmpty {
                        Text("暫無證書")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(certificates, id: \.serialNumber) { cert in
                            VStack(alignment: .leading) {
                                Text(cert.name)
                                Text("SN: \(cert.serialNumber)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    
                    Button("創建新證書") {
                        createCertificate(for: team)
                    }
                    .disabled(isLoading)
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
        .navigationTitle("簽名管理")
        .onAppear {
            loadTeams()
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
                    // 自動選第一個
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
                _ = try await PaxSigningService.shared.createCertificate(for: team)
                await MainActor.run {
                    self.isLoading = false
                }
                // 刷新列表
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
