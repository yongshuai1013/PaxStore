import Foundation
import SwiftUI

/// 檢查 GitHub 最新 release，有新版就提示
class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var downloadURL: URL?
    @Published var statusMessage = ""
    @Published var isChecking = false
    
    private let repo = "yongshuai1013/PaxStore"
    private let currentVersion = "1.0"
    
    func check() {
        isChecking = true
        statusMessage = "檢查中..."
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            DispatchQueue.main.async {
                self.isChecking = false
                self.statusMessage = "檢查失敗"
            }
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isChecking = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.statusMessage = "檢查失敗（無 release）"
                    return
                }
                let ver = tag.replacingOccurrences(of: "v", with: "")
                if ver != self.currentVersion {
                    self.latestVersion = ver
                    if let assets = json["assets"] as? [[String: Any]],
                       let ipa = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }),
                       let dl = ipa["browser_download_url"] as? String,
                       let dlURL = URL(string: dl) {
                        self.downloadURL = dlURL
                    }
                    self.updateAvailable = true
                    self.statusMessage = "發現新版本: \(ver)"
                } else {
                    self.statusMessage = "已是最新版本"
                }
            }
        }.resume()
    }
}
