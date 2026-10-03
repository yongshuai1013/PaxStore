import Foundation
import UIKit

public class PlistInstaller {
    public static let shared = PlistInstaller()
    private init() {}

    private var nioServer: NIOPlistServer?
    public var serverId: String { nioServer?.serverId ?? "" }
    public var port: Int { nioServer?.port ?? 0 }
    public let domain = "ios-sign.duckdns.org"

    private var crtPEM: String {
        guard let url = Bundle.main.url(forResource: "ios-sign", withExtension: "crt"),
              let s = try? String(contentsOf: url) else { return "" }
        if !s.isEmpty { return s }
        return Self.embeddedCrt
    }

    private var keyPEM: String {
        guard let url = Bundle.main.url(forResource: "ios-sign", withExtension: "key"),
              let s = try? String(contentsOf: url) else { return "" }
        if !s.isEmpty { return s }
        return Self.embeddedKey
    }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        let server = NIOPlistServer(crtPEM: crtPEM, keyPEM: keyPEM)
        server.ipaURL = ipaURL
        try server.start()
        server.manifestData = server.makeManifest(bundleId: bundleId, appName: appName, version: version)
        self.nioServer = server
        guard let url = server.plistURL() else {
            throw PlistError.serverFailed("無法構造 plist URL")
        }
        return url
    }

    public func stop() {
        nioServer?.stop()
        nioServer = nil
    }

    public var pendingItmsURL: String {
        get { nioServer?.pendingItmsURL ?? "" }
        set { nioServer?.pendingItmsURL = newValue }
    }

    public func installPageURL() -> URL? {
        return nioServer?.installPageURL()
    }

    public func installTriggerURL(plistURL: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = plistURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let urlStr = "itms-services://?action=download-manifest&url=\(encoded)"
        return URL(string: urlStr)
    }

    public func externalPlistURL(bundleId: String, appName: String, version: String) -> URL? {
        guard let server = nioServer else { return nil }
        let ipaURLStr = "https://\(domain):\(server.port)/\(server.serverId).ipa"
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

extension PlistInstaller {
    static let embeddedCrt = """
-----BEGIN CERTIFICATE-----
MIIDlzCCAx2gAwIBAgISBmgZjx2ovcLOqTFp5bWMffCMMAoGCCqGSM49BAMDMDMx
CzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZ
RTIwHhcNMjYxMDAyMjMyMDU3WhcNMjYxMjMxMjMyMDU2WjAfMR0wGwYDVQQDExRp
b3Mtc2lnbi5kdWNrZG5zLm9yZzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPgB
JqUPAD+vA11F92o3fHdotoW/GzLqsoNWtEdq4tAvZu31aufWuIqAmwSS5gAOflRK
F0oDwRp6fQxaoLOwOiejggIjMIICHzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAww
CgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUhrexog059vub2El8
V58ghJ1RRd0wHwYDVR0jBBgwFoAUuVnyjs8i8IbTN0j/dhQYuoLYVYcwMwYIKwYB
BQUHAQEEJzAlMCMGCCsGAQUFBzAChhdodHRwOi8veWUyLmkubGVuY3Iub3JnLzAf
BgNVHREEGDAWghRpb3Mtc2lnbi5kdWNrZG5zLm9yZzATBgNVHSAEDDAKMAgGBmeB
DAECATAuBgNVHR8EJzAlMCOgIaAfhh1odHRwOi8veWUyLmMubGVuY3Iub3JnLzEz
LmNybDCCAQ0GCisGAQQB1nkCBAIEgf4EgfsA+QB2ANdtfRDRp/V3wsfpX9cAv/mC
yTNaZeHQswFzF8DIxWl3AAABoP8hTqYAAAQDAEcwRQIhAIKXNcLraSCkOVblcR/z
eZxG5pENTQp26lYBUU5yM1ifAiA28efYZJ8oJeaziXxQYSmrT5J/zpcJ1wjWLP+n
2+DyyAB/AI7KRwus3mrzogawpHqEt0b+H8a/lT4l5ptO5AJI88boAAABoP8hUd4A
CAAABQAaopBIBAMASDBGAiEA3pafKTQ+aSkilkl9ZSvYs9J94TbgjcXPKNJ254ZO
ag8CIQCWOy72HDC4mMXkyuP1I0Zl3Nl8bCdMLUHwMOhmiwc/kjAKBggqhkjOPQQD
AwNoADBlAjBONjolDkM56AZtdkY7DG7LGuZ3DXgejSqMrW27sGb7BB5xlQgQ0yrO
aVP16sY/bSICMQC/NmE7IZ5s1k+zQ924HitEN+MSD6ofV7KMpOG5uGKIxXp+EskN
ZNIRF40qi1/Lp18=


MIICjDCCAhGgAwIBAgIQTfOxXdbAeExQfNN7WObxFTAKBggqhkjOPQQDAzAuMQsw
CQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4GA1UEAxMHUm9vdCBZRTAeFw0y
NTA5MDMwMDAwMDBaFw0yODA5MDIyMzU5NTlaMDMxCzAJBgNVBAYTAlVTMRYwFAYD
VQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwdjAQBgcqhkjOPQIBBgUr
gQQAIgNiAARxmrQzkdbEEL3MqXt3dJQttYc47axkdDTHud5TPqM2z5uSD5cmk0Wr
HlWXvnlvqBLqiB34kluxIbmMyAiq3/YD6e80/vV259K8XQIdjFXloYOa0mIU71f7
HQ09PvYDlw+jge4wgeswDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUF
BwMBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLlZ8o7PIvCG0zdI/3YU
GLqC2FWHMB8GA1UdIwQYMBaAFKPIJlqOoUzQNWP8myPIOq5W809WMDIGCCsGAQUF
BwEBBCYwJDAiBggrBgEFBQcwAoYWaHR0cDovL3llLmkubGVuY3Iub3JnLzATBgNV
HSAEDDAKMAgGBmeBDAECATAnBgNVHR8EIDAeMBygGqAYhhZodHRwOi8veWUuYy5s
ZW5jci5vcmcvMAoGCCqGSM49BAMDA2kAMGYCMQDIcnw5dcZLN9ffynXnnkLD/itS
JEycJPb3sRkzeqBowup7vOsAwaqoCnNn/jh9wycCMQCJM6CPlaOC4pQYYbJtVPYb
DKrIb2EKk5NpOpE6/XttQYZV/3gilB9l+Cc/DOVwmyg=


MIICpjCCAiugAwIBAgIRAIchZfw0tuX7qK3Vs3BftTowCgYIKoZIzj0EAwMwTzEL
MAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2VhcmNo
IEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDIwHhcNMjYwNTEzMDAwMDAwWhcN
MzIwOTAyMjM1OTU5WjAuMQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4G
A1UEAxMHUm9vdCBZRTB2MBAGByqGSM49AgEGBSuBBAAiA2IABDwS/6vhrcVqcbBo
+wgdI3fwn9x7DNJJOY/lTOti0vkwuRN87RhEhTH17E7XyFjWsPYhIPt/wzOqxTd2
b+4ZJNy9ID04YywF9U5zasDVyGSNErVNtz8uSGh5izW87j77GaOB6zCB6DAOBgNV
HQ8BAf8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB
/zAdBgNVHQ4EFgQUo8gmWo6hTNA1Y/ybI8g6rlbzT1YwHwYDVR0jBBgwFoAUfEKW
rt5LSDv6kviejM9ti6lyN5UwMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZo
dHRwOi8veDIuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1Ud
HwQgMB4wHKAaoBiGFmh0dHA6Ly94Mi5jLmxlbmNyLm9yZy8wCgYIKoZIzj0EAwMD
aQAwZgIxAMU19WCtmxVND8UHBZRoma49Z7jPs64Dma0eTu1OChVbB/2J7GV3nvYK
Ax54uk1G9QIxAO0miLVJu8PLNiXXXkiE/gsK3CTRTF/aeo4bMX42Zw40csRU6AC2
6hSW1/IWaas6dg==


MIIEcDCCAligAwIBAgIQbI8dxyfHEX97r4U6yYD5zTANBgkqhkiG9w0BAQsFADBP
MQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFy
Y2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMTAeFw0yNjA1MTMwMDAwMDBa
Fw0zMjA5MDIyMzU5NTlaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5l
dCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgy
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0H
ttwW+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7
AlF9ItgKbppbd9/w+kHsOdx1ymgHDB/qo4H1MIHyMA4GA1UdDwEB/wQEAwIBBjAd
BgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwDwYDVR0TAQH/BAUwAwEB/zAd
BgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwHwYDVR0jBBgwFoAUebRZ5nu2
5eQBc4AIiMgaWPbpm24wMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRw
Oi8veDEuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQg
MB4wHKAaoBiGFmh0dHA6Ly94MS5jLmxlbmNyLm9yZy8wDQYJKoZIhvcNAQELBQAD
ggIBAD2/e9frmMxNpCV03qUHegg+MV2wz9644YoXdqtH8RyWYcBO7xfjjGEXdU1e
/o0OkEFiynUCOSIk/vLLo7ttz6CPAeNlWfC0XNkoGeWgK6jjXvozBaGuGH5n0Ufo
shMeWTuURqNN5G00sSXDTBrpp2+mgvdZQjb8K11TYMA25QA+YHNfbIEL0BniAhKS
2gsnJjSzrdZLI+EZ7SEyqdR2rkjd1KutLDU+n3TFyxjniZVGur4YlhMP3mY/dV95
IruAkkjOZier6hGBdEgZXXvaCz9u9iVEadsIE75pAGL8oHV5vxdARDiotRpul1IN
/UZwzAbrfUFcw1HkAcYD/mlZfnQ2ieCF2MS7j3Vhv7JPDKp45fmykmzYNSrumRW0
upFFKDBOoF7hsOb7oLyHS+Uft6jOUfOrogj8YUx38hKb2K20r42OgsSdDdxdeYWc
MS3Sb6mwJeSZEYxJ2gaXnDSPaKhhrNkYwljyVQyr4Nq+MEJytXNTnHqaAcrNwZlV
pcJL1KBnMrMjP7eanvUwL3FYj3cF17jtboLt7gLoi4+2rWZFvn+w54jmd/FIuhhZ
cEaU/wvU6BUNMtcVquVGHp7itQeDth5j+XL3j4WJ2SABwzUl6OeYdgpIt/ITZa+p
TT0mQ/r5XyA4MEAiabn7XJjvCERlF2dcn2wqJw+CreTkkQ2R
-----END CERTIFICATE-----
"""
    static let embeddedKey = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgiZZKQruYlFU101xt
Yvs2pk/GQxInu6zHQzv3oQqRDo2hRANCAAT4ASalDwA/rwNdRfdqN3x3aLaFvxsy
6rKDVrRHauLQL2bt9Wrn1riKgJsEkuYADn5UShdKA8Eaen0MWqCzsDon
-----END PRIVATE KEY-----
"""
}
