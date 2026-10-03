import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import UIKit

public class NIOPlistServer {
    private var group: EventLoopGroup?
    private var channel: Channel?
    public private(set) var port: Int = 0

    public var ipaURL: URL?
    public var manifestData: Data?
    public var serverId: String = UUID().uuidString
    public var pendingItmsURL: String = ""
    public let domain = "ios-sign.duckdns.org"

    private let crtPEM: String
    private let keyPEM: String

    public init(crtPEM: String, keyPEM: String) {
        self.crtPEM = crtPEM
        self.keyPEM = keyPEM
    }

    public func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let certs = try NIOSSLCertificate.fromPEMBytes(Array(crtPEM.utf8)).map {
            NIOSSLCertificateSource.certificate($0)
        }
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        var tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs,
            privateKey: .privateKey(key)
        )
        tlsConfig.minimumTLSVersion = .tlsv12
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let sslHandler = NIOSSLServerHandler(context: sslContext)
                let httpHandler = HTTPHandler(server: server)
                return channel.pipeline.addHandler(sslHandler).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                }.flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "0.0.0.0", port: 0).wait()
        self.channel = channel
        if let localAddr = channel.localAddress, let p = localAddr.port {
            self.port = p
        } else {
            throw PlistError.serverFailed("無法獲取端口")
        }
    }

    public func stop() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }

    public func makeManifest(bundleId: String, appName: String, version: String) -> Data {
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

    public func makeIcon(size: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let img = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        return img.pngData() ?? Data()
    }

    public func plistURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = domain
        comps.port = port
        comps.path = "/\(serverId).plist"
        return comps.url
    }

    public func installPageURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = domain
        comps.port = port
        comps.path = "/install"
        return comps.url
    }
}

private class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: NIOPlistServer
    private var requestHead: HTTPRequestHead?

    init(server: NIOPlistServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
        case .body:
            break
        case .end:
            guard let head = requestHead else { return }
            handleRequest(head: head, context: context)
            requestHead = nil
        }
    }

    private func handleRequest(head: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = head.uri
        var status: HTTPResponseStatus = .ok
        var contentType = "application/octet-stream"
        var body = Data()

        if path == "/\(server.serverId).plist" {
            contentType = "text/xml"
            body = server.manifestData ?? Data()
        } else if path == "/\(server.serverId).ipa" {
            if let url = server.ipaURL, let d = try? Data(contentsOf: url) {
                body = d
            } else {
                status = .notFound
            }
        } else if path == "/icon57.png" {
            contentType = "image/png"
            body = server.makeIcon(size: 57)
        } else if path == "/icon512.png" {
            contentType = "image/png"
            body = server.makeIcon(size: 512)
        } else if path == "/install" {
            contentType = "text/html; charset=utf-8"
            let escaped = server.pendingItmsURL
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let html = """
            <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="font-family:sans-serif;text-align:center;padding-top:60px">
            <h2>正在跳轉到安裝...</h2>
            <p>如果沒有自動跳轉，<a href="\(escaped)">點此安裝</a></p>
            <script>window.location="\(server.pendingItmsURL)";</script>
            </body></html>
            """
            body = Data(html.utf8)
        } else {
            status = .notFound
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
