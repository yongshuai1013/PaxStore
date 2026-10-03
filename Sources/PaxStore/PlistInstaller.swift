import Foundation
import Network
import UIKit
import Security

public class PlistInstaller {
    public static let shared = PlistInstaller()
    private init() {}

    private var listener: NWListener?
    private var ipaURL: URL?
    private var manifestData: Data?
    public let serverId = UUID().uuidString
    public private(set) var port: Int = 0
    public let domain = "ios-sign.duckdns.org"

    private let p12Base64 = "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"

    private func tlsParameters() throws -> NWParameters {
        guard let p12Data = Data(base64Encoded: p12Base64) else {
            throw PlistError.serverFailed("p12 base64 解碼失敗")
        }
        let options = [kSecImportExportPassphrase as String: "paxstore"]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw PlistError.serverFailed("SecPKCS12Import 失敗: \(status)")
        }
        guard let dicts = items as? [[String: Any]],
              let identityValue = dicts.first?[kSecImportItemIdentity as String] else {
            throw PlistError.serverFailed("無法提取 SecIdentity")
        }
        let identity = identityValue as! SecIdentity
        let tlsOptions = NWProtocolTLS.Options()
        guard let secId = sec_identity_create(identity) else {
            throw PlistError.serverFailed("sec_identity_create 失敗")
        }
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secId)
        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        self.ipaURL = ipaURL

        let params = try tlsParameters()
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: 0)
        self.listener = listener

        let sem = DispatchSemaphore(value: 0)
        var actualPort: Int = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                if let p = listener.port?.rawValue {
                    actualPort = Int(p)
                }
                sem.signal()
            } else if case .failed(_) = state {
                sem.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.start(queue: .global())

        _ = sem.wait(timeout: .now() + 5)
        self.port = actualPort
        guard actualPort > 0 else { throw PlistError.serverFailed("無法綁定端口") }

        self.manifestData = makeManifest(bundleId: bundleId, appName: appName, version: version)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = domain
        comps.port = actualPort
        comps.path = "/\(serverId).plist"
        guard let url = comps.url else { throw PlistError.serverFailed("無法構造 plist URL") }
        return url
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func makeManifest(bundleId: String, appName: String, version: String) -> Data {
        let base = "https://\(domain):\(port)"
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

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data,
                  let req = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let path = req.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.respond(to: path, on: conn)
        }
    }

    private func respond(to path: String, on conn: NWConnection) {
        var status = "200 OK"
        var contentType = "application/octet-stream"
        var body = Data()

        if path == "/\(serverId).plist" {
            contentType = "text/xml"
            body = manifestData ?? Data()
        } else if path == "/\(serverId).ipa" {
            contentType = "application/octet-stream"
            if let url = ipaURL, let d = try? Data(contentsOf: url) {
                body = d
            } else {
                status = "404 Not Found"
            }
        } else if path == "/icon57.png" {
            contentType = "image/png"
            body = makeIcon(size: 57)
        } else if path == "/icon512.png" {
            contentType = "image/png"
            body = makeIcon(size: 512)
        } else if path == "/install" {
            contentType = "text/html; charset=utf-8"
            let escaped = pendingItmsURL
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let html = """
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="font-family:sans-serif;text-align:center;padding-top:60px">
            <h2>正在跳轉到安裝...</h2>
            <p>如果沒有自動跳轉，<a href="\(escaped)">點此安裝</a></p>
            <script>window.location="\(pendingItmsURL)";</script>
            </body></html>
            """
            body = Data(html.utf8)
        } else {
            status = "404 Not Found"
        }

        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var resp = Data(header.utf8)
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func makeIcon(size: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        return img.pngData() ?? Data()
    }

    public var pendingItmsURL: String = ""

    public func installPageURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = domain
        comps.port = port
        comps.path = "/install"
        return comps.url
    }

    public func installTriggerURL(plistURL: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = plistURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "itms-services://?action=download-manifest&url=\(encoded)"
        return URL(string: urlStr)
    }

    public func externalPlistURL(bundleId: String, appName: String, version: String) -> URL? {
        let ipaURLStr = "https://\(domain):\(port)/\(serverId).ipa"
        let base = "https://api.palera.in/genPlist?bundleid=\(bundleId)&name=\(appName)&version=\(version)&fetchurl=\(ipaURLStr)"
        guard let encoded = base.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: encoded)
    }

    public func installTriggerURLExternal(bundleId: String, appName: String, version: String) -> URL? {
        guard let plistURL = externalPlistURL(bundleId: bundleId, appName: appName, version: version) else { return nil }
        let urlStr = "itms-services://?action=download-manifest&url=\(plistURL.absoluteString)"
        return URL(string: urlStr)
    }
}

public enum PlistError: LocalizedError {
    case serverFailed(String)
    public var errorDescription: String? {
        switch self {
        case .serverFailed(let msg): return msg
        }
    }
}
