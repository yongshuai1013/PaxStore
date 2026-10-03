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

    private func tlsParameters() -> NWParameters? {
        guard let p12URL = Bundle.main.url(forResource: "ios-sign", withExtension: "p12"),
              let p12Data = try? Data(contentsOf: p12URL) else {
            return nil
        }
        let options = [kSecImportExportPassphrase as String: "paxstore"]
        var items: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let dicts = items as? [[String: Any]],
              let identity = dicts.first?[kSecImportItemIdentity as String] as! SecIdentity? else {
            return nil
        }
        let tlsOptions = NWProtocolTLS.Options()
        let secId = sec_identity_create(identity)!
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secId)
        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        self.ipaURL = ipaURL

        guard let params = tlsParameters() else {
            throw PlistError.serverFailed("無法載入 TLS 證書")
        }
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

public enum PlistError: Error {
    case serverFailed(String)
}
