import Foundation
import SideSign

/// PaxStore 登入服務（用 SideSign，跟 SideStore 同款）
public final class PaxAuthService {
    public static let shared = PaxAuthService()
    
    private let anisetteServers: [URL] = [
        URL(string: "https://ani.sidestore.zip")!,
    ]
    
    private init() {}
    
    /// 登入，成功返回 true，失敗拋錯
    /// - Parameters:
    ///   - appleID: Apple ID
    ///   - password: 密碼
    ///   - verificationCode: 2FA 驗證碼（如果上次登入要求 2FA）
    public func login(appleID: String, password: String, verificationCode: String? = nil) async throws -> Bool {
        // 1. 拿 anisette（穩定身份）
        let identifier = resolveIdentifier()
        let existingBlob: Data? = loadADIBlob()
        
        let manager = SideSign.AnisetteDataManager.shared
        let (anisetteData, newBlob) = try await manager.fetchAnisetteDataWithFailover(
            servers: anisetteServers,
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        
        // 存新的 ADI blob
        if let newBlob = newBlob {
            saveADIBlob(newBlob)
        }
        
        // 2. SideSign 登入
        let portal = SideSign.DeveloperPortal.shared
        
        // 2FA handler：如果有驗證碼就用，沒有就拋錯讓 UI 提示輸入
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler? = verificationCode.map { code in
            { request in
                // 根據請求類型返回驗證碼
                switch request {
                case .trustedDevice, .sms, .voice:
                    return .verificationCode(code)
                case .selectDeliveryMethod:
                    // 預設用受信任設備
                    return .requestTrustedDevice
                }
            }
        }
        
        let session = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: "27.0 (27A242)",
            verificationHandler: verificationHandler
        )
        
        // 3. 存 session（簡化版）
        print("[PaxStore] 登入成功")
        return true
    }
    
    // MARK: - Keychain（簡化版，用 UserDefaults 代替）
    
    private func resolveIdentifier() -> UUID {
        let key = "paxstore.anisette.identifier"
        if let uuidString = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        let newUUID = UUID()
        UserDefaults.standard.set(newUUID.uuidString, forKey: key)
        return newUUID
    }
    
    private func loadADIBlob() -> Data? {
        return UserDefaults.standard.data(forKey: "paxstore.anisette.adiblob")
    }
    
    private func saveADIBlob(_ data: Data) {
        UserDefaults.standard.set(data, forKey: "paxstore.anisette.adiblob")
    }
}
