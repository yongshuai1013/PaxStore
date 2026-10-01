import SwiftUI
import SideSign
import UniformTypeIdentifiers
import ZIPFoundation

struct SigningFlowView: View {
    @State private var teams: [SideSign.Team] = []
    @State private var selectedTeam: SideSign.Team?
    @State private var ipaURL: URL?
    @State private var isPickingIPA = false
    @State private var isSigning = false
    @State private var progressLog = ""
    @State private var signedIPAURL: URL?
    @State private var errorMessage: String?
    @State private var showingShare = false
    
    private let signingService = PaxSigningService.shared
    
    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        progressLog += "[\(ts)] \(msg)\n"
    }
    
    var body: some View {
        Form {
            Section(header: Text("1. 選擇 IPA")) {
                if let url = ipaURL {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                } else {
                    Text("尚未選擇")
                        .foregroundColor(.secondary)
                }
                Button("選擇 IPA 文件") {
                    isPickingIPA = true
                }
                .disabled(isSigning)
            }
            
            Section(header: Text("2. 選擇 Team")) {
                if teams.isEmpty {
                    Text("載入中...")
                } else {
                    Picker("Team", selection: $selectedTeam) {
                        ForEach(teams, id: \.identifier) { team in
                            Text(team.name).tag(team as SideSign.Team?)
                        }
                    }
                }
            }
            
            Section(header: Text("3. 簽名")) {
                Button(isSigning ? "簽名中..." : "開始簽名") {
                    Task { await startSigning() }
                }
                .disabled(ipaURL == nil || selectedTeam == nil || isSigning)
                
                if let err = errorMessage {
                    Text(err).foregroundColor(.red)
                }
            }
            
            if !progressLog.isEmpty {
                Section(header: Text("進度")) {
                    ScrollView {
                        Text(progressLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200)
                }
            }
            
            if let signedURL = signedIPAURL {
                Section(header: Text("完成")) {
                    Text(signedURL.lastPathComponent)
                    Button("分享已簽名 IPA") {
                        showingShare = true
                    }
                    .sheet(isPresented: $showingShare) {
                        ShareSheet(url: signedURL)
                    }
                }
            }
        }
        .navigationTitle("簽名 IPA")
        .fileImporter(isPresented: $isPickingIPA, allowedContentTypes: [.init(filenameExtension: "ipa") ?? .data]) { result in
            switch result {
            case .success(let url):
                // 複製到沙盒內
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    try FileManager.default.copyItem(at: url, to: dest)
                    url.stopAccessingSecurityScopedResource()
                    ipaURL = dest
                    log("已選擇: \(url.lastPathComponent)")
                } catch {
                    errorMessage = "複製文件失敗: \(error.localizedDescription)"
                }
            case .failure(let err):
                errorMessage = "選擇失敗: \(err.localizedDescription)"
            }
        }
        .task {
            await loadTeams()
        }
    }
    
    private func loadTeams() async {
        do {
            teams = try await signingService.fetchTeams()
            selectedTeam = teams.first
        } catch {
            errorMessage = "載入 Team 失敗: \(error.localizedDescription)"
        }
    }
    
    private func startSigning() async {
        guard let ipaURL = ipaURL, let team = selectedTeam else { return }
        isSigning = true
        errorMessage = nil
        signedIPAURL = nil
        progressLog = ""
        
        do {
            log("開始簽名流程...")
            
            // 解包 IPA
            log("解包 IPA...")
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await unzip(ipaURL, to: workDir)
            
            // 找到 .app
            let payload = workDir.appendingPathComponent("Payload")
            let contents = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
                throw SigningError.signingFailed("找不到 .app")
            }
            log("找到 App: \(appURL.lastPathComponent)")
            
            // 解析 Bundle ID（主 App + extensions）
            let bundleIDs = try await extractBundleIDs(from: appURL)
            log("Bundle IDs: \(bundleIDs.joined(separator: ", "))")
            
            // 為每個 Bundle ID 找／建 App ID，下載 profile
            var profiles: [Data] = []
            var profileMap: [String: Data] = [:]
            for bundleID in bundleIDs {
                log("處理 \(bundleID)...")
                let appID = try await signingService.findOrCreateAppID(
                    bundleIdentifier: bundleID,
                    name: bundleID,
                    for: team
                )
                log("  App ID: \(appID.name)")
                
                let profileData = try await signingService.provisioningProfileData(for: appID, team: team)
                profileMap[bundleID] = profileData
                log("  Profile 已下載 (\(profileData.count) bytes)")
            }
            
            // TODO: 嵌入 profiles、簽名、重打包
            // 需要把 profile 寫入 .app/embedded.mobileprovision
            // 然後用 AppBundleSigner 簽名
            log("Profile 準備完成，簽名實作待續...")
            
            // 清理
            // try? FileManager.default.removeItem(at: workDir)
            
        } catch {
            errorMessage = "簽名失敗: \(error.localizedDescription)"
            log("錯誤: \(error)")
        }
        
        isSigning = false
    }
    
    private func unzip(_ src: URL, to dest: URL) async throws {
        try FileManager.default.unzipItem(at: src, to: dest)
    }
    
    private func extractBundleIDs(from appURL: URL) async throws -> [String] {
        var ids: [String] = []
        
        // 主 App
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOf: infoPlist),
           let bid = dict["CFBundleIdentifier"] as? String {
            ids.append(bid)
        }
        
        // Extensions
        let plugIns = appURL.appendingPathComponent("PlugIns")
        if let extensions = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) {
            for ext in extensions where ext.pathExtension == "appex" {
                let extPlist = ext.appendingPathComponent("Info.plist")
                if let dict = NSDictionary(contentsOf: extPlist),
                   let bid = dict["CFBundleIdentifier"] as? String {
                    ids.append(bid)
                }
            }
        }
        
        guard !ids.isEmpty else {
            throw SigningError.signingFailed("無法解析 Bundle ID")
        }
        return ids
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
