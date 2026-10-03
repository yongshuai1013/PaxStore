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

    // 調試日誌
    @State private var debugLog = ""

    // 2FA 代碼提供者
    private let codeProvider = TwoFACodeProvider()

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLog += "[\(timestamp)] \(message)\n"
    }

    var body: some View {
        Group {
            if isLoggedIn {
                MainTabView(appleID: $appleID, isLoggedIn: $isLoggedIn, onLogout: doLogout)
            } else {
                NavigationView {
                    Form {
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
                                log("已清除 Anisette 本地數據")
                                errorMessage = "Anisette 數據已清除，下次登入會重新生成"
                            }
                            .foregroundColor(.red)
                        }

                        // 調試日誌
                        if !debugLog.isEmpty {
                            Section(header: Text("調試日誌")) {
                                ScrollView {
                                    Text(debugLog)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 200)
                                Button("清除日誌") {
                                    debugLog = ""
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .navigationTitle("PaxStore")
                    .onAppear {
                        if PaxAuthService.shared.restoreSession() {
                            if let savedID = PaxAuthService.shared.currentAppleID {
                                appleID = savedID
                            }
                            isLoggedIn = true
                            log("已從 Keychain 恢復登入狀態")
                        }
                        codeProvider.onCodeRequired = {
                            Task { @MainActor in
                                needs2FA = true
                                errorMessage = "Apple 已發送驗證碼，請輸入"
                            }
                        }
                        codeProvider.onMethodRequired = { phones, preferred in
                            Task { @MainActor in
                                availablePhones = phones
                                preferredMethod = preferred
                                showMethodPicker = true
                            }
                        }
                        codeProvider.onLog = { message in
                            Task { @MainActor in
                                log(message)
                            }
                        }
                    }
                    .actionSheet(isPresented: $showMethodPicker) {
                        var buttons: [ActionSheet.Button] = []
                        for phone in availablePhones {
                            let label = phone.number.isEmpty ? phone.id : phone.number
                            buttons.append(.default(Text("SMS: \(label)")) {
                                codeProvider.submitMethod(.sms(phoneID: phone.id))
                            })
                            buttons.append(.default(Text("語音電話: \(label)")) {
                                codeProvider.submitMethod(.voice(phoneID: phone.id))
                            })
                        }
                        if availablePhones.isEmpty {
                            buttons.append(.default(Text("SMS（自動）")) {
                                codeProvider.submitMethod(.sms(phoneID: "1"))
                            })
                            buttons.append(.default(Text("語音電話（自動）")) {
                                codeProvider.submitMethod(.voice(phoneID: "1"))
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
        }
    }

    private func doLogout() {
        PaxAuthService.shared.logout()
        isLoggedIn = false
        appleID = ""
        password = ""
        verificationCode = ""
        needs2FA = false
        log("已登出")
    }

    private func doLogin() {
        isLoading = true
        errorMessage = nil
        needs2FA = false

        loginTask = Task {
            do {
                await MainActor.run { log("開始登入") }
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
                    log("登入失敗: \(error.localizedDescription)")
                    errorMessage = "登入失敗：\(error.localizedDescription)"
                }
            }
        }
    }
}
