import Foundation
import SideSign

/// 2FA 代碼提供者：handler 在同一次 authenticate() 內等待 UI 輸入，不會重發 SMS
public final class TwoFACodeProvider: Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var _onCodeRequired: (@Sendable () -> Void)?
    
    public init() {}
    
    /// UI 設置「需要驗證碼時」的回調（用來顯示輸入框）
    public var onCodeRequired: (@Sendable () -> Void)? {
        get { lock.withLock { _onCodeRequired } }
        set { lock.withLock { _onCodeRequired = newValue } }
    }
    
    /// Handler 調用：等待用戶輸入驗證碼（只會在同一次登入內等待，不重發 SMS）
    public func awaitCode() async -> String {
        // 先通知 UI 顯示輸入框
        if let callback = lock.withLock({ _onCodeRequired }) {
            callback()
        }
        return await withCheckedContinuation { cont in
            lock.withLock {
                continuation = cont
            }
        }
    }
    
    /// UI 調用：用戶輸完碼，喚醒等待中的 handler
    public func submitCode(_ code: String) {
        let cont: CheckedContinuation<String, Never>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(returning: code)
    }
}

/// PaxStore 登入服務（用 SideSign，跟 SideStore 同款）
public final class PaxAuthService {
    public static let shared = PaxAuthService()
    
    private let anisetteServers: [URL] = [
        URL(string: "https://ani.sidestore.zip")!,
    ]
    
    private init() {}
    
    /// 登入（一次 authenticate 內完成 2FA，不會重發 SMS）
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
        
        // 2. SideSign 登入（2FA 在同一次調用內等待輸入）
        let portal = SideSign.DeveloperPortal.shared
        
        let verificationHandler: SideSign.DeveloperPortal.VerificationHandler = { request in
            switch request {
            case .trustedDevice, .sms, .voice:
                // 等待 UI 輸入（不會拋錯重來）
                let code = await codeProvider.awaitCode()
                return .verificationCode(code)
            case .selectDeliveryMethod(_, let phoneNumbers):
                // 優先 SMS
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
