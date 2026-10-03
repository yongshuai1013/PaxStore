import Foundation

// MARK: - 通用日誌
final class AppLogger {
    static let shared = AppLogger()
    private init() {}

    private var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("paxstore.log")
    }

    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        print(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let url = logURL else { return }
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    func read() -> String {
        guard let url = logURL else { return "" }
        return (try? String(contentsOf: url)) ?? ""
    }

    func clear() {
        guard let url = logURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
