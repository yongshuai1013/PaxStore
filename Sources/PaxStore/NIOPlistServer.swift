import Foundation
import NIO
import NIOHTTP1
import UIKit

public class NIOPlistServer {
    private var group: EventLoopGroup?
    private var channel: Channel?
    public private(set) var port: Int = 0

    public var ipaURL: URL?
    public var manifestData: Data?
    public var serverId: String = UUID().uuidString
    public var pendingItmsURL: String = ""

    public init() {}

    public func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let server = self
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPHandler(server: server)
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try bootstrap.bind(host: "localhost", port: 0).wait()
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
        let base = "http://localhost:\(port)"
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
        comps.scheme = "http"
        comps.host = "localhost"
        comps.port = port
        comps.path = "/\(serverId).plist"
        return comps.url
    }

    public func installPageURL() -> URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "localhost"
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
            // 流式傳文件：先發頭，再分塊發 body，避免一次讀進內存卡住 event loop
            guard let url = server.ipaURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[FileAttributeKey.size] as? UInt64 else {
                status = .notFound
                body = Data()
                // fall through to 404 response below
                var h404 = HTTPHeaders()
                h404.add(name: "Content-Type", value: "application/octet-stream")
                h404.add(name: "Content-Length", value: "0")
                h404.add(name: "Connection", value: "close")
                let head404 = HTTPResponseHead(version: .http1_1, status: .notFound, headers: h404)
                context.write(wrapOutboundOut(.head(head404)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    context.close(promise: nil)
                }
                return
            }
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            headers.add(name: "Content-Length", value: "\(fileSize)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            // 後台線程分塊讀，event loop 上寫
            let channel = context.channel
            let handler = self
            DispatchQueue.global(qos: .userInitiated).async {
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    channel.eventLoop.execute {
                        context.writeAndFlush(handler.wrapOutboundOut(.end(nil))).whenComplete { _ in
                            context.close(promise: nil)
                        }
                    }
                    return
                }
                defer { try? handle.close() }
                let chunkSize = 256 * 1024
                while true {
                    let data = handle.readData(ofLength: chunkSize)
                    if data.isEmpty { break }
                    let buf = channel.allocator.buffer(bytes: data)
                    let p = channel.eventLoop.makePromise(of: Void.self)
                    channel.eventLoop.execute {
                        context.writeAndFlush(handler.wrapOutboundOut(.body(.byteBuffer(buf))), promise: p)
                    }
                    try? p.futureResult.wait()
                }
                channel.eventLoop.execute {
                    context.writeAndFlush(handler.wrapOutboundOut(.end(nil))).whenComplete { _ in
                        context.close(promise: nil)
                    }
                }
            }
            return
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
