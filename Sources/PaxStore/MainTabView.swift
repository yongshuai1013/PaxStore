import SwiftUI
import SideSign

// MARK: - 主 Tab 結構
struct MainTabView: View {
    @Binding var appleID: String
    @Binding var isLoggedIn: Bool
    var onLogout: () -> Void

    var body: some View {
        TabView {
            // 主頁
            NavigationView {
                HomeView(appleID: appleID)
            }
            .tabItem {
                Label("主頁", systemImage: "house")
            }

            // 軟體源
            NavigationView {
                SourcesView()
            }
            .tabItem {
                Label("軟體源", systemImage: "link")
            }

            // 簽名安裝
            NavigationView {
                SignInstallView()
            }
            .tabItem {
                Label("簽名安裝", systemImage: "signature")
            }

            // 設定
            NavigationView {
                SettingsView(appleID: $appleID, isLoggedIn: $isLoggedIn, onLogout: onLogout)
            }
            .tabItem {
                Label("設定", systemImage: "gear")
            }
        }
    }
}

// MARK: - 主頁
struct HomeView: View {
    let appleID: String
    var body: some View {
        Form {
            Section(header: Text("PaxStore")) {
                HStack {
                    Text("Apple ID")
                    Spacer()
                    Text(appleID).foregroundColor(.secondary)
                }
            }
            Section(header: Text("說明")) {
                Text("側載工具：簽名 IPA 並安裝到本機。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("主頁")
    }
}

// MARK: - 軟體源
struct SourcesView: View {
    @State private var sources: [String] = []
    private let key = "paxSources"

    var body: some View {
        Form {
            Section(header: Text("已添加的源")) {
                ForEach(sources, id: \.self) { url in
                    NavigationLink(destination: SourceDetailView(sourceURL: url)) {
                        Text(url).font(.caption).lineLimit(1)
                    }
                }
                .onDelete(perform: delete)
            }
            Section {
                NavigationLink("添加軟體源", destination: AddSourceView(sources: $sources))
            }
        }
        .navigationTitle("軟體源")
        .onAppear { load() }
    }

    private func load() {
        sources = UserDefaults.standard.stringArray(forKey: key) ?? []
    }
    private func delete(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        UserDefaults.standard.set(sources, forKey: key)
    }
}

// MARK: - 簽名安裝
struct SignInstallView: View {
    var body: some View {
        Form {
            Section(header: Text("簽名")) {
                NavigationLink("簽名 IPA", destination: SigningFlowView())
                NavigationLink("證書管理", destination: SigningView())
            }
            Section(header: Text("安裝")) {
                NavigationLink("安裝 App", destination: InstallView())
            }
        }
        .navigationTitle("簽名安裝")
    }
}

// MARK: - 設定
struct SettingsView: View {
    @Binding var appleID: String
    @Binding var isLoggedIn: Bool
    var onLogout: () -> Void

    var body: some View {
        Form {
            Section(header: Text("帳號")) {
                if isLoggedIn {
                    HStack {
                        Text("Apple ID")
                        Spacer()
                        Text(appleID).foregroundColor(.secondary)
                    }
                } else {
                    NavigationLink(destination: LoginView(appleID: $appleID, isLoggedIn: $isLoggedIn)) {
                        Text("登入 Apple ID")
                    }
                }
                NavigationLink("App ID 管理", destination: AppIDsView())
                NavigationLink("證書管理", destination: SigningView())
                if isLoggedIn {
                    Button("登出") {
                        onLogout()
                    }
                    .foregroundColor(.red)
                }
            }
            Section(header: Text("設備")) {
                NavigationLink("配對檔管理", destination: PairingFileManagementView())
                NavigationLink("連接配置", destination: ConnectionConfigView())
            }
            Section(header: Text("服務")) {
                NavigationLink(destination: AnisetteServerView()) {
                    HStack {
                        Text("Anisette 伺服器")
                        Spacer()
                        Text(AnisetteServerManager.shared.selectedServer.name)
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                }
            }
            Section(header: Text("工具")) {
                NavigationLink("檔案管理", destination: FileManagerRootView())
                NavigationLink("日誌", destination: LogView())
            }
        }
        .navigationTitle("設定")
    }
}
