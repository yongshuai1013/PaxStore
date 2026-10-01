import Foundation
import SideSign

/// PaxStore 簽名服務：封裝 SideSign 的 DeveloperPortal API
public final class PaxSigningService {
    public static let shared = PaxSigningService()
    
    private init() {}
    
    // MARK: - Session
    
    /// 從 Keychain 讀取已保存的 AuthSession
    private func loadSession() throws -> SideSign.AuthSession {
        guard let session: SideSign.AuthSession = KeychainHelper.loadCodable(
            SideSign.AuthSession.self,
            forKey: "paxstore.auth.session"
        ) else {
            throw SigningError.notLoggedIn
        }
        return session
    }
    
    // MARK: - Teams
    
    /// 獲取該 Apple ID 下的所有 Team
    public func fetchTeams() async throws -> [SideSign.Team] {
        let authSession = try loadSession()
        let portal = SideSign.DeveloperPortal.shared
        let teams = try await portal.fetchTeams(
            for: authSession.account,
            session: authSession.session
        )
        print("[PaxStore] 找到 \(teams.count) 個 Team")
        return teams
    }
    
    // MARK: - Certificates
    
    /// 獲取指定 Team 下的所有證書
    public func fetchCertificates(for team: SideSign.Team) async throws -> [SideSign.X509Certificate] {
        let authSession = try loadSession()
        let portal = SideSign.DeveloperPortal.shared
        let certs = try await portal.fetchCertificates(
            for: team,
            session: authSession.session
        )
        print("[PaxStore] 找到 \(certs.count) 個證書")
        return certs
    }
    
    /// 為指定 Team 創建新的開發證書
    /// - Returns: 包含私鑰的 KeyStore（必須保存好，簽名時要用）
    public func createCertificate(for team: SideSign.Team, machineName: String = "PaxStore") async throws -> SideSign.KeyStore {
        let authSession = try loadSession()
        let portal = SideSign.DeveloperPortal.shared
        let keyStore = try await portal.addCertificate(
            machineName: machineName,
            type: .development,
            to: team,
            session: authSession.session
        )
        print("[PaxStore] 證書創建成功")
        return keyStore
    }
    
    /// 撤銷指定證書
    public func revokeCertificate(_ certificate: SideSign.X509Certificate, for team: SideSign.Team) async throws {
        let authSession = try loadSession()
        let portal = SideSign.DeveloperPortal.shared
        let success = try await portal.revokeCertificate(
            certificate,
            for: team,
            session: authSession.session
        )
        if !success {
            throw SigningError.certificateFailed("撤銷返回失敗")
        }
        print("[PaxStore] 證書已撤銷")
    }
}

// MARK: - Errors

public enum SigningError: LocalizedError {
    case notLoggedIn
    case noTeamFound
    case certificateFailed(String)
    case profileFailed(String)
    case signingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "尚未登入，請先登入 Apple ID"
        case .noTeamFound:
            return "找不到可用的 Team"
        case .certificateFailed(let msg):
            return "證書操作失敗：\(msg)"
        case .profileFailed(let msg):
            return "描述文件操作失敗：\(msg)"
        case .signingFailed(let msg):
            return "簽名失敗：\(msg)"
        }
    }
}
