import SwiftUI

struct ContentView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoggedIn = false
    @State private var vpnInstalled = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("VPN（設備連接）")) {
                    HStack {
                        Text("狀態")
                        Spacer()
                        Text(vpnInstalled ? "已安裝" : "未安裝")
                            .foregroundColor(vpnInstalled ? .green : .red)
                    }
                    Button(vpnInstalled ? "重裝 VPN" : "安裝 VPN") {
                        // TODO: 調用 TunnelVPNManager 安裝
                        vpnInstalled = true
                    }
                }
                
                if isLoggedIn {
                    Section(header: Text("已登入")) {
                        Text(appleID)
                    }
                } else {
                    Section(header: Text("Apple ID 登入")) {
                        TextField("Apple ID", text: $appleID)
                            .autocapitalization(.none)
                        SecureField("密碼", text: $password)
                        Button("登入") {
                            // TODO: 用 SideSign 登入
                            isLoggedIn = true
                        }
                    }
                }
            }
            .navigationTitle("PaxStore")
        }
    }
}
