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

    private func tlsParameters() -> NWParameters? {
        guard let p12Data = Data(base64Encoded: p12Base64) else {
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
