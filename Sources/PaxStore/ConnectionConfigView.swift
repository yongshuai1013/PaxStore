import SwiftUI

struct ConnectionConfigView: View {
    @State private var useLocalVPN = false
    @State private var deviceIP = ""
    @State private var reachable: String = ""
    @State private var bindHost = ""
    @State private var bindPort = ""
    @State private var isChecking = false

    private let defaults = UserDefaults.standard

    var body: some View {
        Form {
            Section {
                Toggle("Use Local VPN", isOn: $useLocalVPN)
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
            }
        }
        .navigationTitle("Connection Config")
        .navigationBarItems(trailing: Button("Confirm") { save() })
        .onAppear { load() }
    }

    private func load() {
        useLocalVPN = defaults.bool(forKey: "useLocalVPN")
        deviceIP = defaults.string(forKey: "manualDeviceIP") ?? ""
        bindHost = defaults.string(forKey: "emproxyBindHost") ?? "127.0.0.1"
        bindPort = defaults.string(forKey: "emproxyBindPort") ?? "51820"
        VPNConnectionChecker.shared.manualGatewayHost = defaults.string(forKey: "manualDeviceIP")
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
}
