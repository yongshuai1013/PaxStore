import Foundation
import SideSign

// MARK: - Signing Flow

extension PaxSigningService {
    /// 查找或創建 App ID
    public func findOrCreateAppID(bundleIdentifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        // 先查找
        let existing = try await portal.fetchAppIDs(for: team, session: session)
        if let found = existing.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return found
        }
        
        // 不存在則創建
        return try await portal.addAppID(withName: name, bundleIdentifier: bundleIdentifier, team: team, session: session)
    }
    
    /// 只開啟 App Groups 單一開關（不重送整包 features，避免 4100）
    public func enableAppGroups(for appID: SideSign.AppID, team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        var modified = appID.copy()
        modified.features = [SideSign.Feature.appGroups: "true"]
        return try await portal.updateAppID(modified, team: team, session: session)
    }
    
    /// 查找或創建 App Group
    public func findOrCreateAppGroup(identifier: String, name: String, for team: SideSign.Team) async throws -> SideSign.AppGroup {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        let existing = try await portal.fetchAppGroups(for: team, session: session)
        if let found = existing.first(where: { $0.identifier == identifier }) {
            return found
        }
        
        return try await portal.addAppGroup(withIdentifier: identifier, name: name, team: team, session: session)
    }
    
    /// 指派 App Groups 到 App ID
    public func assignAppGroups(_ groups: [SideSign.AppGroup], to appID: SideSign.AppID, for team: SideSign.Team) async throws -> SideSign.AppID {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        return try await portal.assignAppGroups(groups, to: appID, team: team, session: session)
    }
    
    /// 獲取 provisioning profile（查找或創建，然後下載）
    public func provisioningProfile(for appID: SideSign.AppID, team: SideSign.Team) async throws -> Data {
        let (_, session) = try await sessionWithFreshAnisette()
        let portal = SideSign.DeveloperPortal.shared
        
        // 查找現有 profile
        let existing = try await portal.listProvisioningProfiles(for: team, session: session)
        if let found = existing.first(where: { $0.bundleIdentifier == appID.bundleIdentifier }) {
            return try await portal.downloadProvisioningProfile(found, session: session)
        }
        
        // 創建新的
        let newProfile = try await portal.createProvisioningProfile(for: appID, team: team, session: session)
        return try await portal.downloadProvisioningProfile(newProfile, session: session)
    }
}
