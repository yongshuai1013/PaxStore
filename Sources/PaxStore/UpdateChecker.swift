import Foundation
import SwiftUI

/// 檢查 GitHub 最新 release，有新版就提示
class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var downloadURL: URL?
    
    private let repo = "yongshuai1013/PaxStore"
    private let currentVersion = "1.0" // TODO: 從 Info.plist 讀
    
    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let ver = tag.replacingOccurrences(of: "v", with: "")
            if ver != self.currentVersion {
                DispatchQueue.main.async {
                    self.latestVersion = ver
                    if let assets = json["assets"] as? [[String: Any]],
                       let ipa = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".ipa") == true }),
                       let dl = ipa["browser_download_url"] as? String,
                       let dlURL = URL(string: dl) {
                        self.downloadURL = dlURL
                    }
                    self.updateAvailable = true
                }
            }
        }.resume()
    }
}
