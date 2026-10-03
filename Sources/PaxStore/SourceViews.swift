import SwiftUI

// MARK: - 軟體源模型（SideStore 格式）
struct AppSource: Codable {
    let name: String
    let identifier: String?
    let apps: [SourceApp]
}

struct SourceApp: Codable, Identifiable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let versionDescription: String?
    let downloadURL: String
    let iconURL: String?
    let size: Int?
    var id: String { bundleIdentifier }
}

// MARK: - 源詳情（App 列表）
struct SourceDetailView: View {
    let sourceURL: String
    @State private var source: AppSource?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("載入中...")
            } else if let source = source {
                List(source.apps) { app in
                    NavigationLink(destination: SourceAppDetailView(app: app)) {
                        HStack {
                            AsyncImage(url: URL(string: app.iconURL ?? "")) { image in
                                image.resizable()
                            } placeholder: {
                                Image(systemName: "app.fill")
                                    .resizable()
                            }
                            .frame(width: 48, height: 48)
                            .cornerRadius(10)
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text("v\(app.version)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else if let error = errorMessage {
                Text(error).foregroundColor(.red).padding()
            }
        }
        .navigationTitle(source?.name ?? "軟體源")
        .onAppear { load() }
    }

    private func load() {
        guard let url = URL(string: sourceURL) else {
            errorMessage = "無效的 URL"
            isLoading = false
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(AppSource.self, from: data)
                await MainActor.run {
                    source = decoded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "載入失敗：\(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - App 詳情＋下載安裝
struct SourceAppDetailView: View {
    let app: SourceApp
    @State private var isDownloading = false
    @State private var downloadedURL: URL?
    @State private var errorMessage: String?
    @State private var showInstaller = false

    var body: some View {
        Form {
            Section {
                HStack {
                    AsyncImage(url: URL(string: app.iconURL ?? "")) { image in
                        image.resizable()
                    } placeholder: {
                        Image(systemName: "app.fill")
                            .resizable()
                    }
                    .frame(width: 64, height: 64)
                    .cornerRadius(14)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.bundleIdentifier).font(.caption).foregroundColor(.secondary)
                        Text("版本 \(app.version)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if let desc = app.versionDescription, !desc.isEmpty {
                Section(header: Text("更新說明")) {
                    Text(desc).font(.caption)
                }
            }
            Section {
                if isDownloading {
                    HStack {
                        ProgressView()
                        Text("下載中...").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Button("下載並安裝") {
                        download()
                    }
                }
                if let error = errorMessage {
                    Text(error).foregroundColor(.red).font(.caption)
                }
            }
            NavigationLink(
                destination: Group {
                    if let url = downloadedURL {
                        InstallView(initialIPAURL: url)
                    }
                },
                isActive: $showInstaller
            ) {
                EmptyView()
            }
            .hidden()
        }
        .navigationTitle(app.name)
    }

    private func download() {
        guard let url = URL(string: app.downloadURL) else {
            errorMessage = "無效的下載連結"
            return
        }
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(app.bundleIdentifier)_\(app.version).ipa")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                await MainActor.run {
                    downloadedURL = dest
                    isDownloading = false
                    showInstaller = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = "下載失敗：\(error.localizedDescription)"
                    isDownloading = false
                }
            }
        }
    }
}

// MARK: - 添加軟體源（設定頁風格）
struct AddSourceView: View {
    @Binding var sources: [String]
    @State private var newURL = ""
    @Environment(\.presentationMode) var presentationMode
    private let key = "paxSources"

    var body: some View {
        Form {
            Section(header: Text("源地址"), footer: Text("支援 SideStore 格式的軟體源")) {
                TextField("https://...", text: $newURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            Section {
                Button("添加") {
                    let u = newURL.trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty && !sources.contains(u) {
                        sources.append(u)
                        UserDefaults.standard.set(sources, forKey: key)
                    }
                    presentationMode.wrappedValue.dismiss()
                }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("添加軟體源")
    }
}
