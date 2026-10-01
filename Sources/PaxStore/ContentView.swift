import SwiftUI

struct ContentView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var isLoggedIn = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    
    var body: some View {
        NavigationView {
            Form {
                if isLoggedIn {
                    Section(header: Text("已登入")) {
                        Text(appleID)
                        Button("登出") {
                            isLoggedIn = false
                            appleID = ""
                            password = ""
                        }
                        .foregroundColor(.red)
                    }
                } else {
                    Section(header: Text("Apple ID 登入（SideSign）")) {
                        TextField("Apple ID", text: $appleID)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                        SecureField("密碼", text: $password)
                        
                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        
                        Button(action: doLogin) {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("登入")
                            }
                        }
                        .disabled(isLoading || appleID.isEmpty || password.isEmpty)
                    }
                    
                    Section(footer: Text("VPN 外置：請確保外部 VPN 已連接（10.7.0.1 可達）")) {
                        EmptyView()
                    }
                }
            }
            .navigationTitle("PaxStore")
        }
    }
    
    private func doLogin() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let success = try await PaxAuthService.shared.login(
                    appleID: appleID,
                    password: password
                )
                await MainActor.run {
                    isLoading = false
                    if success {
                        isLoggedIn = true
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "登入失敗：\(error.localizedDescription)"
                }
            }
        }
    }
}
