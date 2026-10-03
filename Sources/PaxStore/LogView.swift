import SwiftUI

// MARK: - 日誌查看
struct LogView: View {
    @State private var logContent = ""
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        VStack {
            ScrollView {
                Text(logContent.isEmpty ? "無日誌" : logContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            HStack {
                Button("刷新") { load() }
                Spacer()
                Button("分享") {
                    if let url = logFileURL() {
                        shareURL = url
                        showShare = true
                    }
                }
                .disabled(logContent.isEmpty)
                Spacer()
                Button("清除") { clear() }
                    .foregroundColor(.red)
            }
            .padding()
        }
        .navigationTitle("日誌")
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                ShareSheet(url: url)
            }
        }
        .onAppear { load() }
    }

    private func logFileURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("paxstore.log")
    }

    private func load() {
        logContent = AppLogger.shared.read()
    }

    private func clear() {
        AppLogger.shared.clear()
        logContent = ""
    }
}
