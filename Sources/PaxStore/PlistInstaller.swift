import Foundation
import UIKit

public class PlistInstaller {
    public static let shared = PlistInstaller()
    private init() {}

    private var nioServer: NIOPlistServer?
    public var serverId: String { nioServer?.serverId ?? "" }
    public var port: Int { nioServer?.port ?? 0 }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        AppLogger.shared.log("PlistInstaller.start: bundleId=\(bundleId), ipa=\(ipaURL.lastPathComponent)")
        AudioKeepAlive.shared.start()
        let server = NIOPlistServer()
        server.ipaURL = ipaURL
        try server.start()
        server.manifestData = server.makeManifest(bundleId: bundleId, appName: appName, version: version)
        self.nioServer = server
        guard let url = server.plistURL() else {
            throw PlistError.serverFailed("無法構造 plist URL")
        }
        AppLogger.shared.log("PlistInstaller.start: plistURL=\(url.absoluteString), port=\(server.port), host=\(server.externalHost)")
        return url
    }

    public func stop() {
        AppLogger.shared.log("PlistInstaller.stop")
        nioServer?.stop()
        nioServer = nil
        AudioKeepAlive.shared.stop()
    }

    public var pendingItmsURL: String {
        get { nioServer?.pendingItmsURL ?? "" }
        set { nioServer?.pendingItmsURL = newValue }
    }

    public func installPageURL() -> URL? {
        return nioServer?.installPageURL()
    }

        public func ipaURLString() -> String? {
        guard let server = nioServer else { return nil }
        return "https://\(server.externalHost):\(server.port)/\(server.serverId).ipa"
    }

public func installTriggerURL(plistURL: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = plistURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "itms-services://?action=download-manifest&url=\(encoded)"
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

