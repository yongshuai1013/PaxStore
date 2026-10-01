//
//  TunnelVPNManager.swift
//  PaxStore
//
//  主 App 側的本地 VPN 管理器：用 NETunnelProviderManager 安裝/啟停
//  PaxStoreTunnel（Packet Tunnel Provider），替代已廢棄的 .mobileconfig 方案。
//
//  流程：
//  1. install()：loadAllFromPreferences 找已有配置，沒有則新建
//     NETunnelProviderProtocol（providerBundleIdentifier = com.paxstore.app.tunnel），
//     saveToPreferences（首次會彈系統授權框「PaxStore 想加入 VPN 配置」）
//  2. 保存後重新 load，startVPNTunnel() 啟動隧道
//  3. stop()：stopVPNTunnel()
//
//  注意：
//  - 主 App 不需要 networkextension entitlement，只有 extension 需要
//  - 用戶必須在系統彈框點「允許」，否則 save 失敗
//  - 狀態：靜態實現，未真機驗證

import Foundation
import NetworkExtension

/// Tunnel VPN 錯誤
public enum TunnelVPNError: Error, LocalizedError {
    case saveFailed(String)
    case startFailed(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let r): return "VPN 配置保存失敗：\(r)"
        case .startFailed(let r): return "VPN 啟動失敗：\(r)"
        case .notConfigured: return "VPN 尚未安裝"
        }
    }
}

public final class TunnelVPNManager: Sendable {

    public static let shared = TunnelVPNManager()

    /// Packet Tunnel Provider 的 Bundle ID（須與 project.yml 的 PaxStoreTunnel target 一致，
    //  且為主 App Bundle ID 的前綴：com.paxstore.app.tunnel）
    public let providerBundleIdentifier = "com.paxstore.app.tunnel"

    private init() {}

    // MARK: - 配置管理

    /// 載入已保存的 manager；沒有則返回一個新的（未保存）
    private func loadManager() async throws -> NETunnelProviderManager {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let existing = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                        == self.providerBundleIdentifier
                })
                continuation.resume(returning: existing ?? NETunnelProviderManager())
            }
        }
    }

    private func saveManager(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation(function: #function) { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error = error {
                    continuation.resume(throwing: TunnelVPNError.saveFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - 對外接口

    /// 安裝（或更新）VPN 配置並啟動隧道。
    /// 首次調用會彈系統授權框，用戶點「允許」後才真正寫入。
    public func install() async throws {
        let manager = try await loadManager()

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "PaxStore Local"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "PaxStore VPN"
        manager.isEnabled = true

        try await saveManager(manager)

        // 重新載入已保存的配置再啟動（確保拿到持久化後的 connection）
        let saved = try await loadManager()
        do {
            try saved.connection.startVPNTunnel()
        } catch {
            throw TunnelVPNError.startFailed(error.localizedDescription)
        }
    }

    /// 啟動已安裝的 VPN（不重寫配置）
    public func start() async throws {
        let manager = try await loadManager()
        guard manager.protocolConfiguration != nil else {
            throw TunnelVPNError.notConfigured
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw TunnelVPNError.startFailed(error.localizedDescription)
        }
    }

    /// 停止 VPN
    public func stop() async throws {
        let manager = try await loadManager()
        manager.connection.stopVPNTunnel()
    }

    /// 當前 VPN 狀態；未安裝時返回 .invalid
    public func currentStatus() async -> NEVPNStatus {
        do {
            let manager = try await loadManager()
            guard manager.protocolConfiguration != nil else { return .invalid }
            return manager.connection.status
        } catch {
            return .invalid
        }
    }

    /// 是否已安裝配置
    public func isInstalled() async -> Bool {
        do {
            let manager = try await loadManager()
            return manager.protocolConfiguration != nil
        } catch {
            return false
        }
    }

    /// 狀態的中文描述（供 UI 直接顯示，避免 UI 層 import NetworkExtension）
    public func statusText() async -> String {
        switch await currentStatus() {
        case .invalid: return "未安裝"
        case .disconnected: return "已安裝，未連接"
        case .connecting: return "連接中…"
        case .connected: return "已連接 ✓"
        case .reasserting: return "重連中…"
        case .disconnecting: return "斷開中…"
        @unknown default: return "未知"
        }
    }
}
