import Foundation

/// Anisette 伺服器
public struct AnisetteServer: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let url: String
    
    public init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
    
    public var nsURL: URL? { URL(string: url) }
}

/// 內建伺服器列表（跟 SideStore 一致）
public let builtinAnisetteServers: [AnisetteServer] = [
    AnisetteServer(id: "sidestore-io", name: "SideStore", url: "https://ani.sidestore.io"),
    AnisetteServer(id: "sidestore-app", name: "SideStore (.app)", url: "https://ani.sidestore.app"),
    AnisetteServer(id: "sidestore-zip", name: "SideStore (.zip)", url: "https://ani.sidestore.zip"),
    AnisetteServer(id: "sidestore-xyz", name: "SideStore (.xyz)", url: "https://ani.846969.xyz"),
    AnisetteServer(id: "nythepegasus", name: "nythepegasus", url: "https://ani.npeg.us"),
    AnisetteServer(id: "macley", name: "Macley", url: "http://5.249.163.88:6969"),
    AnisetteServer(id: "we-studio", name: "WE. Studio", url: "https://anisette.wedotstud.io"),
    AnisetteServer(id: "stex", name: "SteX", url: "https://ani.xu30.top"),
    AnisetteServer(id: "owoellen", name: "owoellen", url: "https://ani.owoellen.rocks"),
]

/// Server 選擇管理
public final class AnisetteServerManager {
    public static let shared = AnisetteServerManager()
    
    private let selectedKey = "paxstore.anisette.selectedServerID"
    private let customKey = "paxstore.anisette.customServers"
    
    private init() {}
    
    /// 所有可用伺服器（內建＋自訂）
    public var allServers: [AnisetteServer] {
        builtinAnisetteServers + customServers
    }
    
    /// 自訂伺服器
    public var customServers: [AnisetteServer] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customKey),
                  let servers = try? JSONDecoder().decode([AnisetteServer].self, from: data) else {
                return []
            }
            return servers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: customKey)
            }
        }
    }
    
    /// 當前選中的伺服器
    public var selectedServer: AnisetteServer {
        let id = UserDefaults.standard.string(forKey: selectedKey) ?? "sidestore-zip"
        return allServers.first(where: { $0.id == id }) ?? builtinAnisetteServers[2]
    }
    
    public func select(_ server: AnisetteServer) {
        UserDefaults.standard.set(server.id, forKey: selectedKey)
    }
    
    public func addCustom(name: String, url: String) {
        var customs = customServers
        customs.append(AnisetteServer(name: name, url: url))
        customServers = customs
    }
    
    public func removeCustom(_ server: AnisetteServer) {
        customServers = customServers.filter { $0.id != server.id }
        // 如果刪的是當前選中的，切回預設
        if selectedServer.id == server.id {
            UserDefaults.standard.set("sidestore-zip", forKey: selectedKey)
        }
    }
}
