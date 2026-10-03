import SwiftUI
import SideSign

// MARK: - 下載描述檔（自己填 Bundle ID）
struct ProfileDownloadView: View {
    @State private var bundleID = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var profileURL: URL?
    @State private var showShare = false

    var body: some View {
        Form {
            Section(header: Text("Bundle ID"), footer: Text("填要簽名的 App 的 Bundle ID，例如 com.example.myapp")) {
                TextField("com.example.myapp", text: $bundleID)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
            }
            Section {
                Button(action: download) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("下載描述檔")
                    }
                }
                .disabled(isLoading || bundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error = errorMessage {
                    Text(error).foregroundColor(.red).font(.caption)
                }
            }
        }
        .navigationTitle("下載描述檔")
        .sheet(isPresented: $showShare) {
            if let url = profileURL {
                ShareSheet(url: url)
            }
        }
    }

    private func download() {
        let bid = bundleID.trimmingCharacters(in: .whitespaces)
        guard !bid.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let service = PaxSigningService.shared
                let teams = try await service.fetchTeams()
                guard let team = teams.first else {
                    throw SigningError.noTeamFound
                }
                // 找現有 App ID，沒有就建一個
                let appIDs = try await service.fetchAppIDs(for: team)
                let appID: SideSign.AppID
                if let existing = appIDs.first(where: { $0.bundleIdentifier == bid }) {
                    appID = existing
                } else {
                    appID = try await service.createAppID(name: bid, bundleIdentifier: bid, for: team)
                }
                let profile = try await service.provisioningProfile(for: appID, team: team)
                let filename = bid + ".mobileprovision"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try profile.data.write(to: url)
                await MainActor.run {
                    profileURL = url
                    isLoading = false
                    showShare = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "下載失敗：\(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}
