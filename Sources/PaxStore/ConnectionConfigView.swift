import SwiftUI

struct ConnectionConfigView: View {
    @State private var deviceIP = ""
    @State private var reachable: String = ""
    @State private var isChecking = false

    var body: some View {
        Form {
            Section(header: Text("REMOTE ENDPOINT")) {
                TextField("Device IP", text: $deviceIP)
                    .keyboardType(.decimalPad)
                    .autocapitalization(.none)
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
            }
            Section {
                Button("保存") {
                    VPNConnectionChecker.shared.manualGatewayHost = deviceIP.trimmingCharacters(in: .whitespaces)
                }
                Button("清除手動設置（恢復自動）") {
                    VPNConnectionChecker.shared.manualGatewayHost = nil
                    deviceIP = ""
                }
                .foregroundColor(.red)
            }
            Section(header: Text("說明")) {
                Text("Device IP 為必填。留空則使用自動發現的值（默認 10.7.0.1）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Connection Config")
        .onAppear {
            deviceIP = VPNConnectionChecker.shared.manualGatewayHost ?? ""
        }
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
