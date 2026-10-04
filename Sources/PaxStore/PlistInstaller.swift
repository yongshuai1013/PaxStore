import Foundation
import UIKit

public class PlistInstaller {
    public static let shared = PlistInstaller()
    private init() {}

    private var gcdServer: GCDPlistServer?
    public var serverId: String { gcdServer?.serverId ?? "" }
    public var port: Int { gcdServer?.port ?? 0 }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        AppLogger.shared.log("PlistInstaller.start: bundleId=\(bundleId), ipa=\(ipaURL.lastPathComponent)")
        AudioKeepAlive.shared.start()
        let server = GCDPlistServer()
        server.ipaURL = ipaURL
        try server.start()
        server.manifestData = server.makeManifest(bundleId: bundleId, appName: appName, version: version)
        self.gcdServer = server
        guard let url = server.plistURL() else {
            throw PlistError.serverFailed("無法構造 plist URL")
        }
        AppLogger.shared.log("PlistInstaller.start: plistURL=\(url.absoluteString), port=\(server.port), host=\(server.externalHost)")
        return url
    }

    public func stop() {
        AppLogger.shared.log("PlistInstaller.stop")
        gcdServer?.stop()
        gcdServer = nil
        AudioKeepAlive.shared.stop()
    }

    public var pendingItmsURL: String {
        get { gcdServer?.pendingItmsURL ?? "" }
        set { gcdServer?.pendingItmsURL = newValue }
    }

    public func installPageURL() -> URL? {
        return gcdServer?.installPageURL()
    }

        public func ipaURLString() -> String? {
        guard let server = gcdServer else { return nil }
        return "http://\(server.externalHost):\(server.port)/\(server.serverId).ipa"
    }

public func installTriggerURL(plistURL: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = plistURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "itms-services://?action=download-manifest&url=\(encoded)"
        return URL(string: urlStr)
    }

    public func externalPlistURL(bundleId: String, appName: String, version: String) -> URL? {
        guard let server = gcdServer else { return nil }
        let ipaURLStr = "http://\(server.externalHost):\(server.port)/\(server.serverId).ipa"
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

