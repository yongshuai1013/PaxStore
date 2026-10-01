import Foundation
import SideSign

/// 2FA 代碼提供者：handler 在同一次 authenticate() 內等待 UI 輸入，不會重發 SMS
public final class TwoFACodeProvider: Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var pendingCode: String?
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
        // 檢查是否有已提交但還沒取走的碼（處理競態）
        if let code = lock.withLock({ () -> String? in
            let c = pendingCode
            pendingCode = nil
            return c
        }) {
            return code
        }
        return await withCheckedContinuation { cont in
            lock.withLock {
                // 再次檢查（雙重檢查鎖定）
                if let code = pendingCode {
                    pendingCode = nil
                    cont.resume(returning: code)
                } else {
                    continuation = cont
                }
            }
        }
    }
    
    /// UI 調用：用戶輸完碼，喚醒等待中的 handler（或暫存，等 handler 來取）
    public func submitCode(_ code: String) {
        let cont: CheckedContinuation<String, Never>? = lock.withLock {
            if let c = continuation {
                continuation = nil
                return c
            } else {
                // handler 還沒掛起，先存起來
                pendingCode = code
                return nil
            }
        }
        cont?.resume(returning: code)
    }
}

/// PaxStore 登入服務（用 SideSign，跟 SideStore 同款）
public final class PaxAuthService {
    public static let shared = PaxAuthService()
    
    private init() {}
    
    /// 登入時用的 anisette 伺服器列表（自動輪換開→按優先順序 failover）
    private var anisetteServers: [URL] {
        let urls = AnisetteServerManager.shared.serversForLogin()
        return urls.isEmpty ? [URL(string: "https://ani.sidestore.zip")!] : urls
    }
    
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
                // 去掉可能的空格
                let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[PaxStore] 提交 2FA 碼: \(cleanCode.count) 位")
                return .verificationCode(cleanCode)
            case .selectDeliveryMethod(let preferredMode, let phoneNumbers):
                print("[PaxStore] Apple 建議的 2FA 方式: \(preferredMode), 可用電話: \(phoneNumbers.count)")
                // 尊重 Apple 的建議順序，但優先 SMS（用戶明確要測 SMS）
                // 如果 Apple 建議 trustedDevice 且有可用設備，先試 trustedDevice
                switch preferredMode {
                case .sms, .voice:
                    if let firstPhone = phoneNumbers.first {
                        let mode = preferredMode == .voice ? "voice" : "sms"
                        print("[PaxStore] 請求 \(mode): \(firstPhone.number)")
                        if mode == "voice" {
                            return .requestVoice(phoneID: firstPhone.id)
                        } else {
                            return .requestSMS(phoneID: firstPhone.id)
                        }
                    }
                    return .requestTrustedDevice
                case .trustedDevice:
                    // 用戶反饋設備碼不彈，直接用 SMS
                    if let firstPhone = phoneNumbers.first {
                        print("[PaxStore] 設備碼不彈，改用 SMS: \(firstPhone.number)")
                        return .requestSMS(phoneID: firstPhone.id)
                    }
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
        
        print("[PaxStore] 登入成功")
        return true
    }
    
    // MARK: - Reset
    
    /// 清除本地 Anisette 數據（對應 SideStore 的 Reset adi.pb）
    public func resetAnisette() {
        UserDefaults.standard.removeObject(forKey: "paxstore.anisette.identifier")
        UserDefaults.standard.removeObject(forKey: "paxstore.anisette.adiblob")
        print("[PaxStore] Anisette 數據已清除")
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
