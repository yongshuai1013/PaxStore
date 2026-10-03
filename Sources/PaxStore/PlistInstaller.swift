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
              let s = try? String(contentsOf: url), !s.isEmpty else {
            guard let d = Data(base64Encoded: Self.embeddedCrtB64),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }
        return s
    }

    private var keyPEM: String {
        guard let url = Bundle.main.url(forResource: "ios-sign", withExtension: "key"),
              let s = try? String(contentsOf: url), !s.isEmpty else {
            guard let d = Data(base64Encoded: Self.embeddedKeyB64),
                  let s = String(data: d, encoding: .utf8) else { return "" }
            return s
        }
        return s
    }

    public func start(ipaURL: URL, bundleId: String, appName: String, version: String) throws -> URL {
        AudioKeepAlive.shared.start()
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
        AudioKeepAlive.shared.stop()
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
    static let embeddedCrtB64 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURsekNDQXgyZ0F3SUJBZ0lTQm1nWmp4Mm92Y0xPcVRGcDViV01mZkNNTUFvR0NDcUdTTTQ5QkFNRE1ETXgKQ3pBSkJnTlZCQVlUQWxWVE1SWXdGQVlEVlFRS0V3MU1aWFFuY3lCRmJtTnllWEIwTVF3d0NnWURWUVFERXdOWgpSVEl3SGhjTk1qWXhNREF5TWpNeU1EVTNXaGNOTWpZeE1qTXhNak15TURVMldqQWZNUjB3R3dZRFZRUURFeFJwCmIzTXRjMmxuYmk1a2RXTnJaRzV6TG05eVp6QlpNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VIQTBJQUJQZ0IKSnFVUEFEK3ZBMTFGOTJvM2ZIZG90b1cvR3pMcXNvTld0RWRxNHRBdlp1MzFhdWZXdUlxQW13U1M1Z0FPZmxSSwpGMG9Ed1JwNmZReGFvTE93T2llamdnSWpNSUlDSHpBT0JnTlZIUThCQWY4RUJBTUNCNEF3RXdZRFZSMGxCQXd3CkNnWUlLd1lCQlFVSEF3RXdEQVlEVlIwVEFRSC9CQUl3QURBZEJnTlZIUTRFRmdRVWhyZXhvZzA1OXZ1YjJFbDgKVjU4Z2hKMVJSZDB3SHdZRFZSMGpCQmd3Rm9BVXVWbnlqczhpOEliVE4wai9kaFFZdW9MWVZZY3dNd1lJS3dZQgpCUVVIQVFFRUp6QWxNQ01HQ0NzR0FRVUZCekFDaGhkb2RIUndPaTh2ZVdVeUxta3ViR1Z1WTNJdWIzSm5MekFmCkJnTlZIUkVFR0RBV2doUnBiM010YzJsbmJpNWtkV05yWkc1ekxtOXlaekFUQmdOVkhTQUVEREFLTUFnR0JtZUIKREFFQ0FUQXVCZ05WSFI4RUp6QWxNQ09nSWFBZmhoMW9kSFJ3T2k4dmVXVXlMbU11YkdWdVkzSXViM0puTHpFegpMbU55YkRDQ0FRMEdDaXNHQVFRQjFua0NCQUlFZ2Y0RWdmc0ErUUIyQU5kdGZSRFJwL1Yzd3NmcFg5Y0F2L21DCnlUTmFaZUhRc3dGekY4REl4V2wzQUFBQm9QOGhUcVlBQUFRREFFY3dSUUloQUlLWE5jTHJhU0NrT1ZibGNSL3oKZVp4RzVwRU5UUXAyNmxZQlVVNXlNMWlmQWlBMjhlZllaSjhvSmVhemlYeFFZU21yVDVKL3pwY0oxd2pXTFArbgoyK0R5eUFCL0FJN0tSd3VzM21yem9nYXdwSHFFdDBiK0g4YS9sVDRsNXB0TzVBSkk4OGJvQUFBQm9QOGhVZDRBCkNBQUFCUUFhb3BCSUJBTUFTREJHQWlFQTNwYWZLVFErYVNraWxrbDlaU3ZZczlKOTRUYmdqY1hQS05KMjU0Wk8KYWc4Q0lRQ1dPeTcySERDNG1NWGt5dVAxSTBabDNObDhiQ2RNTFVId01PaG1pd2Mva2pBS0JnZ3Foa2pPUFFRRApBd05vQURCbEFqQk9Oam9sRGtNNTZBWnRka1k3REc3TEd1WjNEWGdlalNxTXJXMjdzR2I3QkI1eGxRZ1EweXJPCmFWUDE2c1kvYlNJQ01RQy9ObUU3SVo1czFrK3pROTI0SGl0RU4rTVNENm9mVjdLTXBPRzV1R0tJeFhwK0Vza04KWk5JUkY0MHFpMS9McDE4PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCi0tLS0tQkVHSU4gQ0VSVElGSUNBVEUtLS0tLQpNSUlDakRDQ0FoR2dBd0lCQWdJUVRmT3hYZGJBZUV4UWZOTjdXT2J4RlRBS0JnZ3Foa2pPUFFRREF6QXVNUXN3CkNRWURWUVFHRXdKVlV6RU5NQXNHQTFVRUNoTUVTVk5TUnpFUU1BNEdBMVVFQXhNSFVtOXZkQ0JaUlRBZUZ3MHkKTlRBNU1ETXdNREF3TURCYUZ3MHlPREE1TURJeU16VTVOVGxhTURNeEN6QUpCZ05WQkFZVEFsVlRNUll3RkFZRApWUVFLRXcxTVpYUW5jeUJGYm1OeWVYQjBNUXd3Q2dZRFZRUURFd05aUlRJd2RqQVFCZ2NxaGtqT1BRSUJCZ1VyCmdRUUFJZ05pQUFSeG1yUXprZGJFRUwzTXFYdDNkSlF0dFljNDdheGtkRFRIdWQ1VFBxTTJ6NXVTRDVjbWswV3IKSGxXWHZubHZxQkxxaUIzNGtsdXhJYm1NeUFpcTMvWUQ2ZTgwL3ZWMjU5SzhYUUlkakZYbG9ZT2EwbUlVNzFmNwpIUTA5UHZZRGx3K2pnZTR3Z2Vzd0RnWURWUjBQQVFIL0JBUURBZ0dHTUJNR0ExVWRKUVFNTUFvR0NDc0dBUVVGCkJ3TUJNQklHQTFVZEV3RUIvd1FJTUFZQkFmOENBUUF3SFFZRFZSME9CQllFRkxsWjhvN1BJdkNHMHpkSS8zWVUKR0xxQzJGV0hNQjhHQTFVZEl3UVlNQmFBRktQSUpscU9vVXpRTldQOG15UElPcTVXODA5V01ESUdDQ3NHQVFVRgpCd0VCQkNZd0pEQWlCZ2dyQmdFRkJRY3dBb1lXYUhSMGNEb3ZMM2xsTG1rdWJHVnVZM0l1YjNKbkx6QVRCZ05WCkhTQUVEREFLTUFnR0JtZUJEQUVDQVRBbkJnTlZIUjhFSURBZU1CeWdHcUFZaGhab2RIUndPaTh2ZVdVdVl5NXMKWlc1amNpNXZjbWN2TUFvR0NDcUdTTTQ5QkFNREEya0FNR1lDTVFESWNudzVkY1pMTjlmZnluWG5ua0xEL2l0UwpKRXljSlBiM3NSa3plcUJvd3VwN3ZPc0F3YXFvQ25Obi9qaDl3eWNDTVFDSk02Q1BsYU9DNHBRWVliSnRWUFliCkRLckliMkVLazVOcE9wRTYvWHR0UVlaVi8zZ2lsQjlsK0NjL0RPVndteWc9Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0KLS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUNwakNDQWl1Z0F3SUJBZ0lSQUljaFpmdzB0dVg3cUszVnMzQmZ0VG93Q2dZSUtvWkl6ajBFQXdNd1R6RUwKTUFrR0ExVUVCaE1DVlZNeEtUQW5CZ05WQkFvVElFbHVkR1Z5Ym1WMElGTmxZM1Z5YVhSNUlGSmxjMlZoY21ObwpJRWR5YjNWd01SVXdFd1lEVlFRREV3eEpVMUpISUZKdmIzUWdXREl3SGhjTk1qWXdOVEV6TURBd01EQXdXaGNOCk16SXdPVEF5TWpNMU9UVTVXakF1TVFzd0NRWURWUVFHRXdKVlV6RU5NQXNHQTFVRUNoTUVTVk5TUnpFUU1BNEcKQTFVRUF4TUhVbTl2ZENCWlJUQjJNQkFHQnlxR1NNNDlBZ0VHQlN1QkJBQWlBMklBQkR3Uy82dmhyY1ZxY2JCbword2dkSTNmd245eDdETkpKT1kvbFRPdGkwdmt3dVJOODdSaEVoVEgxN0U3WHlGaldzUFloSVB0L3d6T3F4VGQyCmIrNFpKTnk5SUQwNFl5d0Y5VTV6YXNEVnlHU05FclZOdHo4dVNHaDVpelc4N2o3N0dhT0I2ekNCNkRBT0JnTlYKSFE4QkFmOEVCQU1DQVFZd0V3WURWUjBsQkF3d0NnWUlLd1lCQlFVSEF3RXdEd1lEVlIwVEFRSC9CQVV3QXdFQgovekFkQmdOVkhRNEVGZ1FVbzhnbVdvNmhUTkExWS95Ykk4ZzZybGJ6VDFZd0h3WURWUjBqQkJnd0ZvQVVmRUtXCnJ0NUxTRHY2a3ZpZWpNOXRpNmx5TjVVd01nWUlLd1lCQlFVSEFRRUVKakFrTUNJR0NDc0dBUVVGQnpBQ2hoWm8KZEhSd09pOHZlREl1YVM1c1pXNWpjaTV2Y21jdk1CTUdBMVVkSUFRTU1Bb3dDQVlHWjRFTUFRSUJNQ2NHQTFVZApId1FnTUI0d0hLQWFvQmlHRm1oMGRIQTZMeTk0TWk1akxteGxibU55TG05eVp5OHdDZ1lJS29aSXpqMEVBd01ECmFRQXdaZ0l4QU1VMTlXQ3RteFZORDhVSEJaUm9tYTQ5WjdqUHM2NERtYTBlVHUxT0NoVmJCLzJKN0dWM252WUsKQXg1NHVrMUc5UUl4QU8wbWlMVkp1OFBMTmlYWFhraUUvZ3NLM0NUUlRGL2FlbzRiTVg0Mlp3NDBjc1JVNkFDMgo2aFNXMS9JV2FhczZkZz09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0KLS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUVjRENDQWxpZ0F3SUJBZ0lRYkk4ZHh5ZkhFWDk3cjRVNnlZRDV6VEFOQmdrcWhraUc5dzBCQVFzRkFEQlAKTVFzd0NRWURWUVFHRXdKVlV6RXBNQ2NHQTFVRUNoTWdTVzUwWlhKdVpYUWdVMlZqZFhKcGRIa2dVbVZ6WldGeQpZMmdnUjNKdmRYQXhGVEFUQmdOVkJBTVRERWxUVWtjZ1VtOXZkQ0JZTVRBZUZ3MHlOakExTVRNd01EQXdNREJhCkZ3MHpNakE1TURJeU16VTVOVGxhTUU4eEN6QUpCZ05WQkFZVEFsVlRNU2t3SndZRFZRUUtFeUJKYm5SbGNtNWwKZENCVFpXTjFjbWwwZVNCU1pYTmxZWEpqYUNCSGNtOTFjREVWTUJNR0ExVUVBeE1NU1ZOU1J5QlNiMjkwSUZneQpNSFl3RUFZSEtvWkl6ajBDQVFZRks0RUVBQ0lEWWdBRXpadlZuNENEQ3V3SlN2TVdTajVjejNlczNtY0ZEUjBICnR0d1crMXFMRk52aWNXREV1a1dWRVltTzZnYmY5eW9XSEtTNXhjVXk0QVBnSG9JWU9JdlhSZGdLYW03bUFIZjcKQWxGOUl0Z0ticHBiZDkvdytrSHNPZHgxeW1nSERCL3FvNEgxTUlIeU1BNEdBMVVkRHdFQi93UUVBd0lCQmpBZApCZ05WSFNVRUZqQVVCZ2dyQmdFRkJRY0RBUVlJS3dZQkJRVUhBd0l3RHdZRFZSMFRBUUgvQkFVd0F3RUIvekFkCkJnTlZIUTRFRmdRVWZFS1dydDVMU0R2Nmt2aWVqTTl0aTZseU41VXdId1lEVlIwakJCZ3dGb0FVZWJSWjVudTIKNWVRQmM0QUlpTWdhV1BicG0yNHdNZ1lJS3dZQkJRVUhBUUVFSmpBa01DSUdDQ3NHQVFVRkJ6QUNoaFpvZEhSdwpPaTh2ZURFdWFTNXNaVzVqY2k1dmNtY3ZNQk1HQTFVZElBUU1NQW93Q0FZR1o0RU1BUUlCTUNjR0ExVWRId1FnCk1CNHdIS0Fhb0JpR0ZtaDBkSEE2THk5NE1TNWpMbXhsYm1OeUxtOXlaeTh3RFFZSktvWklodmNOQVFFTEJRQUQKZ2dJQkFEMi9lOWZybU14TnBDVjAzcVVIZWdnK01WMnd6OTY0NFlvWGRxdEg4UnlXWWNCTzd4ZmpqR0VYZFUxZQovbzBPa0VGaXluVUNPU0lrL3ZMTG83dHR6NkNQQWVObFdmQzBYTmtvR2VXZ0s2ampYdm96QmFHdUdINW4wVWZvCnNoTWVXVHVVUnFOTjVHMDBzU1hEVEJycHAyK21ndmRaUWpiOEsxMVRZTUEyNVFBK1lITmZiSUVMMEJuaUFoS1MKMmdzbkpqU3pyZFpMSStFWjdTRXlxZFIycmtqZDFLdXRMRFUrbjNURnl4am5pWlZHdXI0WWxoTVAzbVkvZFY5NQpJcnVBa2tqT1ppZXI2aEdCZEVnWlhYdmFDejl1OWlWRWFkc0lFNzVwQUdMOG9IVjV2eGRBUkRpb3RScHVsMUlOCi9VWnd6QWJyZlVGY3cxSGtBY1lEL21sWmZuUTJpZUNGMk1TN2ozVmh2N0pQREtwNDVmbXlrbXpZTlNydW1SVzAKdXBGRktEQk9vRjdoc09iN29MeUhTK1VmdDZqT1VmT3JvZ2o4WVV4MzhoS2IySzIwcjQyT2dzU2REZHhkZVlXYwpNUzNTYjZtd0plU1pFWXhKMmdhWG5EU1BhS2hock5rWXdsanlWUXlyNE5xK01FSnl0WE5UbkhxYUFjck53WmxWCnBjSkwxS0JuTXJNalA3ZWFudlV3TDNGWWozY0YxN2p0Ym9MdDdnTG9pNCsycldaRnZuK3c1NGptZC9GSXVoaFoKY0VhVS93dlU2QlVOTXRjVnF1VkdIcDdpdFFlRHRoNWorWEwzajRXSjJTQUJ3elVsNk9lWWRncEl0L0lUWmErcApUVDBtUS9yNVh5QTRNRUFpYWJuN1hKanZDRVJsRjJkY24yd3FKdytDcmVUa2tRMlIKLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo="
    static let embeddedKeyB64 = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JR0hBZ0VBTUJNR0J5cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEJHMHdhd0lCQVFRZ2laWktRcnVZbEZVMTAxeHQKWXZzMnBrL0dReEludTZ6SFF6djNvUXFSRG8yaFJBTkNBQVQ0QVNhbER3QS9yd05kUmZkcU4zeDNhTGFGdnhzeQo2cktEVnJSSGF1TFFMMmJ0OVdybjFyaUtnSnNFa3VZQURuNVVTaGRLQThFYWVuME1XcUN6c0RvbgotLS0tLUVORCBQUklWQVRFIEtFWS0tLS0tCg=="
}
