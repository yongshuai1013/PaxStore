import SwiftUI

struct ConnectionConfigView: View {
    @State private var useLocalVPN = false
    @State private var deviceIP = ""
    @State private var reachable: String = ""
    @State private var bindHost = ""
    @State private var bindPort = ""
    @State private var isChecking = false
    @State private var emproxyRunning = false
    @State private var emproxyMsg = ""
    @State private var tunnelIP = ""
    @State private var autoDeviceIP = ""

    private let defaults = UserDefaults.standard

    var body: some View {
        Form {
            Section {
                Toggle("Use Local VPN", isOn: $useLocalVPN)
            }

            Section(header: Text("AUTO DISCOVERED FROM NETWORK")) {
                HStack {
                    Text("Tunnel IP")
                    Spacer()
                    Text(tunnelIP.isEmpty ? "—" : tunnelIP)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Device IP")
                    Spacer()
                    Text(autoDeviceIP.isEmpty ? "—" : autoDeviceIP)
                        .foregroundColor(.secondary)
                }
            }

            Section(header: Text("REMOTE ENDPOINT")) {
                HStack {
                    Text("Device IP")
                    Spacer()
                    TextField("10.7.0.1", text: $deviceIP)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                }
                HStack {
                    Text("Reachable")
                    Spacer()
                    Text(reachable)
                        .foregroundColor(reachable == "Yes" ? .green : .secondary)
                }
                Button("檢測連通性") {
                    Task { await checkReachable() }
                }
                .disabled(isChecking)
                Text("Note: 'Device IP' is mandatory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("WIREGUARD SERVER PARAMETERS")) {
                HStack {
                    Text("Bind Host / IP")
                    Spacer()
                    TextField("127.0.0.1", text: $bindHost)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                }
                HStack {
                    Text("Bind Port")
                    Spacer()
                    TextField("51820", text: $bindPort)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                Text("Configures the local UDP loopback host and port bound by EMProxy.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("EMProxy 狀態")
                    Spacer()
                    Text(emproxyRunning ? "運行中" : "已停止")
                        .foregroundColor(emproxyRunning ? .green : .secondary)
                }
                Button(emproxyRunning ? "停止 EMProxy" : "啟動 EMProxy") {
                    toggleEMProxy()
                }
                if !emproxyMsg.isEmpty {
                    Text(emproxyMsg)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Connection Config")
        .onAppear {
            discoverNetwork()
        }
        .navigationBarItems(trailing: Button("Confirm") { save() })
        .onAppear { load() }
    }

    private func load() {
        useLocalVPN = defaults.bool(forKey: "useLocalVPN")
        deviceIP = defaults.string(forKey: "manualDeviceIP") ?? ""
        bindHost = defaults.string(forKey: "emproxyBindHost") ?? "127.0.0.1"
        bindPort = defaults.string(forKey: "emproxyBindPort") ?? "51820"
        VPNConnectionChecker.shared.manualGatewayHost = defaults.string(forKey: "manualDeviceIP")
        emproxyRunning = EMProxyManager.shared.isRunning
    }

    private func save() {
        defaults.set(useLocalVPN, forKey: "useLocalVPN")
        let ip = deviceIP.trimmingCharacters(in: .whitespaces)
        if ip.isEmpty {
            defaults.removeObject(forKey: "manualDeviceIP")
            VPNConnectionChecker.shared.manualGatewayHost = nil
        } else {
            defaults.set(ip, forKey: "manualDeviceIP")
            VPNConnectionChecker.shared.manualGatewayHost = ip
        }
        defaults.set(bindHost.trimmingCharacters(in: .whitespaces), forKey: "emproxyBindHost")
        defaults.set(bindPort.trimmingCharacters(in: .whitespaces), forKey: "emproxyBindPort")
    }

    private func checkReachable() async {
        isChecking = true
        defer { isChecking = false }
        let ip = deviceIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else {
            reachable = "請先輸入 IP"
            return
        }
        let ok = await VPNConnectionChecker.shared.tcpProbe(host: ip, port: 62078, timeoutMs: 3000)
        reachable = ok ? "Yes" : "No"
    }

    private func toggleEMProxy() {
        if EMProxyManager.shared.isRunning {
            let rc = EMProxyManager.shared.stop()
            emproxyRunning = false
            emproxyMsg = rc == 0 ? "已停止" : "停止失敗: \(rc)"
        } else {
            let host = bindHost.trimmingCharacters(in: .whitespaces)
            let port = UInt16(bindPort.trimmingCharacters(in: .whitespaces)) ?? 51820
            let rc = EMProxyManager.shared.start(bindHost: host.isEmpty ? "127.0.0.1" : host, bindPort: port)
            emproxyRunning = EMProxyManager.shared.isRunning
            emproxyMsg = rc == 0 ? "已啟動 \(host):\(port)" : "啟動失敗: \(rc)"
        }
    }

    private func discoverNetwork() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let curr = ptr {
            let ifa = curr.pointee
            if let addrPtr = ifa.ifa_addr,
               addrPtr.pointee.sa_family == UInt8(AF_INET),
               let cname = ifa.ifa_name {
                let ifName = String(cString: cname)
                if ifName.hasPrefix("utun") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addrPtr, socklen_t(addrPtr.pointee.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: hostname)
                        var prefix = 32
                        if let nm = ifa.ifa_netmask {
                            let s = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                                $0.pointee.sin_addr.s_addr
                            }
                            prefix = UInt32(bigEndian: s).nonzeroBitCount
                        }
                        tunnelIP = "\(ip)/\(prefix)"
                        let parts = ip.split(separator: ".")
                        if parts.count == 4 {
                            autoDeviceIP = "\(parts[0]).\(parts[1]).\(parts[2]).1/32"
                        }
                        break
                    }
                }
            }
            ptr = ifa.ifa_next
        }
    }
