import SwiftUI

struct ContentView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var isLoggedIn = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var needs2FA = false
    
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
                            verificationCode = ""
                            needs2FA = false
                        }
                        .foregroundColor(.red)
                    }
                } else {
                    Section(header: Text("Apple ID 登入（SideSign）")) {
                        TextField("Apple ID", text: $appleID)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                        SecureField("密碼", text: $password)
                        
                        if needs2FA {
                            TextField("2FA 驗證碼", text: $verificationCode)
                                .keyboardType(.numberPad)
                        }
                        
                        if let error = errorMessage {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        
                        Button(action: doLogin) {
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(needs2FA ? "驗證並登入" : "登入")
                            }
                        }
                        .disabled(isLoading || appleID.isEmpty || password.isEmpty || (needs2FA && verificationCode.isEmpty))
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
                    password: password,
                    verificationCode: needs2FA ? verificationCode : nil
                )
                await MainActor.run {
                    isLoading = false
                    if success {
                        isLoggedIn = true
                        needs2FA = false
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    let msg = error.localizedDescription
                    // 檢測是否需要 2FA
                    if msg.contains("two-factor") || msg.contains("2FA") {
                        needs2FA = true
                        errorMessage = "請輸入 Apple 發送的 2FA 驗證碼"
                    } else {
                        errorMessage = "登入失敗：\(msg)"
                    }
                }
            }
        }
    }
}
