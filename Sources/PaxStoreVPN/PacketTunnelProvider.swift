import NetworkExtension
import WireGuardKit

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var wgAdapter: WireGuardAdapter?
    
    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let protocolConfig = self.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        
        // 從配置中讀取 WireGuard 參數
        guard let wgConfigString = providerConfig["wgConfig"] as? String else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        
        do {
            let wgConfig = try WgConfig(from: wgConfigString)
            
            wgAdapter = WireGuardAdapter(with: self) { logLevel, message in
                NSLog("[WG] \(message)")
            }
            
            // 設置隧道網絡參數
            let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
            
            // IPv4 設置
            let ipv4Settings = NEIPv4Settings(addresses: ["10.7.0.10"], subnetMasks: ["255.255.255.0"])
            ipv4Settings.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")]
            tunnelNetworkSettings.ipv4Settings = ipv4Settings
            
            // DNS 設置（可選）
            tunnelNetworkSettings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8"])
            
            setTunnelNetworkSettings(tunnelNetworkSettings) { error in
                if let error = error {
                    completionHandler(error)
                    return
                }
                
                self.wgAdapter?.start(config: wgConfig) { error in
                    completionHandler(error)
                }
            }
        } catch {
            completionHandler(error)
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        wgAdapter?.stop { _ in
            completionHandler()
        }
        wgAdapter = nil
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // 處理來自主 App 的消息
        completionHandler?(nil)
    }
}
