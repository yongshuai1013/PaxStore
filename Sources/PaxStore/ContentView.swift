import SwiftUI
import SideSign

struct ContentView: View {
    @State private var appleID = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var isLoggedIn = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var needs2FA = false
    @State private var loginTask: Task<Void, Never>?
    
    // 2FA 方式選擇彈窗
    @State private var showMethodPicker = false
    @State private var availablePhones: [TrustedPhoneNumber] = []
    @State private var preferredMethod: TwoFactorDeliveryMode = .sms
    
    // 2FA 代碼提供者
    private let codeProvider = TwoFACodeProvider()
    
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
                            .disabled(isLoading)
                        SecureField("密碼", text: $password)
                            .disabled(isLoading)
                        
                        if needs2FA {
                            TextField("2FA 驗證碼（SMS 已發送）", text: $verificationCode)
                                .keyboardType(.numberPad)
                            
                            Button("提交驗證碼") {
                                codeProvider.submitCode(verificationCode)
                                verificationCode = ""
                            }
                            .disabled(verificationCode.isEmpty)
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
                                Text("登入")
                            }
                        }
                        .disabled(isLoading || appleID.isEmpty || password.isEmpty)
                    }
                    
                    Section(footer: Text("VPN 外置：請確保外部 VPN 已連接（10.7.0.1 可達）")) {
                        NavigationLink(destination: AnisetteServerView()) {
                            HStack {
                                Text("Anisette 伺服器")
                                Spacer()
                                Text(AnisetteServerManager.shared.selectedServer.name)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                        }
                        Button("Reset Anisette（清除本地數據）") {
                            PaxAuthService.shared.resetAnisette()
                            errorMessage = "Anisette 數據已清除，下次登入會重新生成"
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("PaxStore")
            .onAppear {
                // 設置驗證碼回調：handler 需要碼時顯示輸入框
                codeProvider.onCodeRequired = {
                    Task { @MainActor in
                        needs2FA = true
                        errorMessage = "Apple 已發送驗證碼，請輸入"
                    }
                }
                // 設置方式選擇回調：彈窗讓用戶選
                codeProvider.onMethodRequired = { phones, preferred in
                    Task { @MainActor in
                        availablePhones = phones
                        preferredMethod = preferred
                        showMethodPicker = true
                    }
                }
            }
            .actionSheet(isPresented: $showMethodPicker) {
                var buttons: [ActionSheet.Button] = []
                
                // 受信任設備
                buttons.append(.default(Text("受信任設備\(preferredMethod == .trustedDevice ? "（推薦）" : "")")) {
                    codeProvider.submitMethod(.trustedDevice)
                })
                
                // 每個電話號碼的 SMS 和語音
                for phone in availablePhones {
                    let label = phone.number.isEmpty ? phone.id : phone.number
                    buttons.append(.default(Text("SMS: \(label)")) {
                        codeProvider.submitMethod(.sms(phoneID: phone.id))
                    })
                    buttons.append(.default(Text("語音電話: \(label)")) {
                        codeProvider.submitMethod(.voice(phoneID: phone.id))
                    })
                }
                
                buttons.append(.cancel(Text("取消")))
                
                return ActionSheet(
                    title: Text("選擇驗證方式"),
                    message: Text("Apple 需要驗證你的身份"),
                    buttons: buttons
                )
            }
        }
    }
    
    private func doLogin() {
        isLoading = true
        errorMessage = nil
        needs2FA = false
        
        loginTask = Task {
            do {
                let success = try await PaxAuthService.shared.login(
                    appleID: appleID,
                    password: password,
                    codeProvider: codeProvider
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
                    // 取消等待中的 handler（如果用戶取消）
                    errorMessage = "登入失敗：\(error.localizedDescription)"
                }
            }
        }
    }
}
