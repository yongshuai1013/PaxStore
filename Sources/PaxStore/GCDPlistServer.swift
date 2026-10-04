import Foundation

// MARK: - GCDWebServer 版本地安裝服務（LCSign 同款庫）
final class GCDPlistServer {
    public private(set) var port: Int = 0
    public var ipaURL: URL?
    public var manifestData: Data?
    public var serverId: String = UUID().uuidString
    public var pendingItmsURL: String = ""

    private var webServer: GCDWebServer?

    public var externalHost: String {
        if let url = webServer?.serverURL, let host = url.host {
            return host
        }
        return "127.0.0.1"
    }

    public func start() throws {
        let server = GCDWebServer()
        let sid = serverId

        server.addHandler(forMethod: "GET", path: "/\(sid).plist", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let data = self?.manifestData else {
                return GCDWebServerResponse(statusCode: 404)
            }
            return GCDWebServerDataResponse(data: data, contentType: "application/xml")
        }

        server.addHandler(forMethod: "GET", path: "/\(sid).ipa", request: GCDWebServerRequest.self) { [weak self] _ in
            guard let url = self?.ipaURL, let data = try? Data(contentsOf: url) else {
                return GCDWebServerResponse(statusCode: 404)
            }
            return GCDWebServerDataResponse(data: data, contentType: "application/octet-stream")
        }

        server.addHandler(forMethod: "GET", path: "/icon57.png", request: GCDWebServerRequest.self) { _ in
            GCDWebServerDataResponse(data: Data(), contentType: "image/png")
        }
        server.addHandler(forMethod: "GET", path: "/icon512.png", request: GCDWebServerRequest.self) { _ in
            GCDWebServerDataResponse(data: Data(), contentType: "image/png")
        }

        guard server.start(withPort: 0, bonjourName: "") else {
            throw PlistError.serverFailed("GCDWebServer 啟動失敗")
        }
        self.webServer = server
        self.port = Int(server.port)
        AppLogger.shared.log("GCDPlistServer.start: port=\(self.port), url=\(server.serverURL?.absoluteString ?? "-")")
    }

    public func stop() {
        webServer?.stop()
        webServer = nil
    }

    public func makeManifest(bundleId: String, appName: String, version: String) -> Data {
        let base = "http://\(externalHost):\(port)"
        let manifest: [String: Any] = [
            "items": [[
                "assets": [
                    ["kind": "software-package", "url": "\(base)/\(serverId).ipa"],
                    ["kind": "display-image", "url": "\(base)/icon57.png"],
                    ["kind": "full-size-image", "url": "\(base)/icon512.png"],
                ],
                "metadata": [
                    "bundle-identifier": bundleId,
                    "bundle-version": version,
                    "kind": "software",
                    "title": appName,
                ],
            ]],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)) ?? Data()
    }

    public func plistURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = externalHost
        comps.port = port
        comps.path = "/\(serverId).plist"
        return comps.url
    }

    public func installPageURL() -> URL? { nil }
}
