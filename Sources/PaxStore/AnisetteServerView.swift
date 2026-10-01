import SwiftUI

struct AnisetteServerView: View {
    @State private var servers: [AnisetteServer] = AnisetteServerManager.shared.allServers
    @State private var selectedID: String = AnisetteServerManager.shared.selectedServer.id
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    
    var body: some View {
        List {
            Section(header: Text("AVAILABLE SERVERS")) {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    Button(action: {
                        AnisetteServerManager.shared.select(server)
                        selectedID = server.id
                    }) {
                        HStack {
                            Text("#\(index + 1)")
                                .foregroundColor(.gray)
                                .font(.caption)
                                .frame(width: 30, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(server.name)
                                    .foregroundColor(.primary)
                                Text(server.url)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            Spacer()
                            if server.id == selectedID {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.purple)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        // 只允許刪除自訂的
                        if !builtinAnisetteServers.contains(where: { $0.id == server.id }) {
                            Button(role: .destructive) {
                                AnisetteServerManager.shared.removeCustom(server)
                                refresh()
                            } label: {
                                Label("刪除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Anisette 伺服器")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationView {
                Form {
                    TextField("名稱", text: $newName)
                    TextField("URL（https://...）", text: $newURL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                }
                .navigationTitle("新增伺服器")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("加入") {
                            guard !newName.isEmpty, !newURL.isEmpty,
                                  URL(string: newURL) != nil else { return }
                            AnisetteServerManager.shared.addCustom(name: newName, url: newURL)
                            newName = ""
                            newURL = ""
                            showingAdd = false
                            refresh()
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
    }
    
    private func refresh() {
        servers = AnisetteServerManager.shared.allServers
        selectedID = AnisetteServerManager.shared.selectedServer.id
    }
}
