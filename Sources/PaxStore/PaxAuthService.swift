import Foundation
import SideSign

/// 2FA 代碼提供者（橋接 UI 和 SideSign handler）
public final class TwoFACodeProvider: Sendable {
    private let lock = NSLock()
    private var _code: String?
    
    public init() {}
    
    public var code: String? {
        get { lock.withLock { _code } }
        set { lock.withLock { _code = newValue } }
    }
}

/// PaxStore 登入服務（用 SideSign，跟 SideStore 同款）
public final class PaxAuthService {
    public static let shared = PaxAuthService()
    
    private let anisetteServers: [URL] = [
        URL(string: "https://ani.sidestore.zip")!,
    ]
    
    private init() {}
    
    /// 登入，成功返回 true
    /// - Parameters:
    ///   - appleID: Apple ID
    ///   - password: 密碼
    ///   - codeProvider: 2FA 代碼提供者（UI 設置代碼）
    /// - Throws: 如果需要 2FA 但沒提供代碼，拋 PaxAuthError.twoFactorRequired
    public func login(appleID: String, password: String, codeProvider: TwoFACodeProvider = TwoFACodeProvider()) async throws -> Bool {
        // 1. 拿 anisette（穩定身份）
        let identifier = resolveIdentifier()
        let existingBlob: Data? = loadADIBlob()
        
        let manager = SideSign.AnisetteDataManager.shared
        let (anisetteData, newBlob) = try await manager.fetchAnisetteDataWithFailover(
            servers: anisetteServers,
            identifier: identifier,
            existingAdiBlob: existingBlob
        )
        
        if let newBlob = newBlob {
            saveADIBlob(newBlob)
        }
        
        // 2. SideSign 登入（帶 2FA handler，優先 SMS）
        let portal = SideSign.DeveloperPortal.shared
        
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler = { request in
            switch request {
            case .trustedDevice, .sms, .voice:
                // 需要驗證碼：看 UI 有沒有提供
                if let code = codeProvider.code, !code.isEmpty {
                    return .verificationCode(code)
                }
                // 沒碼：拋錯，讓 UI 顯示輸入框
                throw PaxAuthError.twoFactorRequired
            case .selectDeliveryMethod(_, let phoneNumbers):
                // 優先 SMS（此類帳號只能走 SMS）
                if let firstPhone = phoneNumbers.first {
                    return .requestSMS(phoneID: firstPhone.id)
                }
                return .requestTrustedDevice
            }
        }
        
        let session = try await portal.authenticate(
            appleID: appleID,
            password: password,
            anisetteData: anisetteData,
            xcodeVersion: "27.0 (27A242)",
            verificationHandler: verificationHandler
        )
        
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

public enum PaxAuthError: Error, LocalizedError {
    case twoFactorRequired
    
    public var errorDescription: String? {
        switch self {
        case .twoFactorRequired:
            return "請輸入 Apple 發送的 2FA 驗證碼"
        }
    }
}
