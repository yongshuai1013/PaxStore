import Foundation
import Network
import Security

/// Lockdown 協議客戶端（經 VPN 隧道連接設備）
public class LockdownClient {
    private var connection: NWConnection?
    public let host: String
    public let port: UInt16
    private var sessionID: String?
    private var hostID: String?
    private var pairIdentity: SecIdentity?
    
    public init(host: String = "10.7.0.1", port: UInt16 = 62078) {
        self.host = host
        self.port = port
    }
    
    /// PEM 轉 DER
    private func derFromPEM(_ pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        let b64 = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        return Data(base64Encoded: b64)
    }
    
    /// 從配對檔建立 SecIdentity（經 Keychain）
    private func makeIdentity(hostCertPEM: String, hostKeyPEM: String) throws -> SecIdentity {
        guard let certDER = derFromPEM(hostCertPEM) else { throw LockdownError.missingCredentials }
        guard let keyDER = derFromPEM(hostKeyPEM) else { throw LockdownError.missingCredentials }
        
        // 按 PEM 頭判斷：RSA PRIVATE KEY = PKCS#1（需包成 PKCS#8），PRIVATE KEY = PKCS#8（直接用）
        var keyData = keyDER
        if hostKeyPEM.contains("RSA PRIVATE KEY") {
            guard let wrapped = wrapPKCS1inPKCS8(keyDER) else {
                throw LockdownError.tlsSetupFailed("PKCS#1 包裝失敗")
            }
            keyData = wrapped
        }
        
        // 先清掉舊的（避免重複）
        let delKey: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "PaxStorePairing".data(using: .utf8)!]
        SecItemDelete(delKey as CFDictionary)
        let delCert: [String: Any] = [kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "PaxStorePairing"]
        SecItemDelete(delCert as CFDictionary)
        
        // 導入私鑰（不指定 keySize，讓系統自動識別）
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var err: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyData as CFData, keyAttrs as CFDictionary, &err) else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "未知錯誤"
            throw LockdownError.tlsSetupFailed("私鑰導入失敗: \(msg) (DER \(keyData.count) 字節)")
        }
        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "PaxStorePairing".data(using: .utf8)!,
            kSecValueRef as String: secKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemAdd(addKey as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("私鑰存 Keychain 失敗: \(status)") }
        
        // 導入證書
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw LockdownError.tlsSetupFailed("證書解析失敗")
        }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: "PaxStorePairing",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        status = SecItemAdd(addCert as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else { throw LockdownError.tlsSetupFailed("證書存 Keychain 失敗: \(status)") }
        
        // 取 Identity（系統會自動把匹配的 key+cert 組成 identity）
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "PaxStorePairing",
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &item)
        // 若按 label 找不到，嘗試用證書找
        if status != errSecSuccess {
            let q2: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecValueRef as String: cert,
                kSecReturnRef as String: true,
            ]
            status = SecItemCopyMatching(q2 as CFDictionary, &item)
        }
        guard status == errSecSuccess, let identity = item as! SecIdentity? else {
            throw LockdownError.tlsSetupFailed("Identity 組裝失敗: \(status)")
        }
        return identity
    }
    
    private func wrapPKCS1inPKCS8(_ pkcs1: Data) -> Data? {
        // PKCS#8 頭 (RSA-2048): SEQUENCE { INTEGER 0, SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }, OCTET STRING <pkcs1> }
        // 手工組 ASN.1
        var out = Data()
        func lenBytes(_ n: Int) -> Data {
            if n < 128 { return Data([UInt8(n)]) }
            var v = n; var b: [UInt8] = []
            while v > 0 { b.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([UInt8(0x80 | b.count)] + b)
        }
        let oidPart = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let intZero = Data([0x02, 0x01, 0x00])
        var octet = Data([0x04]); octet.append(lenBytes(pkcs1.count)); octet.append(pkcs1)
        var inner = intZero + oidPart + octet
        var seq = Data([0x30]); seq.append(lenBytes(inner.count)); seq.append(inner)
        return seq
    }
    
    /// 使用配對檔建立 TLS 連接並完成 lockdown 握手
    public func connect(pairingFileURL: URL) async throws {
        guard let plist = NSDictionary(contentsOf: pairingFileURL) as? [String: Any] else {
            throw LockdownError.invalidPairingFile
        }
        guard let hostCertPEM = (plist["HostCertificate"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }) ?? (plist["HostCertificate"] as? String),
              let hostKeyPEM = (plist["HostPrivateKey"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }) ?? (plist["HostPrivateKey"] as? String),
              let hostID = plist["HostID"] as? String else {
            throw LockdownError.missingCredentials
        }
        self.hostID = hostID
        
        let identity = try makeIdentity(hostCertPEM: hostCertPEM, hostKeyPEM: hostKeyPEM)
        self.pairIdentity = identity
        
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )
        // 不驗證服務器證書（lockdownd 用自簽名 DeviceCertificate）
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .global())
        
        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection?.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: LockdownError.connectionCancelled)
                default: break
                }
            }
            connection?.start(queue: .global())
        }
        
        // --- lockdown 握手 ---
        // 1. QueryType
        let qt = try await sendPlist(["Label": "PaxStore", "Request": "QueryType"])
        guard (qt["Type"] as? String) == "com.apple.mobile.lockdown" else {
            throw LockdownError.handshakeFailed("QueryType 回應異常")
        }
        // 2. ValidatePair
        var pairRecord = plist
        // PairRecord 不需要包含 HostCertificate 等，只傳設備相關的（簡化：傳整個 plist，lockdownd 會忽略多餘欄位）
        let vp = try await sendPlist(["Label": "PaxStore", "Request": "ValidatePair", "PairRecord": pairRecord])
        guard (vp["Result"] as? String) == "Success" else {
            throw LockdownError.handshakeFailed("ValidatePair 失敗: \(vp)")
        }
        // 3. StartSession
        let ss = try await sendPlist(["Label": "PaxStore", "Request": "StartSession", "HostID": hostID])
        guard (ss["Result"] as? String) == "Success" else {
            throw LockdownError.handshakeFailed("StartSession 失敗: \(ss)")
        }
        self.sessionID = ss["SessionID"] as? String
    }
    
    /// 發送 plist 消息並接收回應
    public func sendPlist(_ dict: [String: Any]) async throws -> [String: Any] {
        guard let connection = connection else { throw LockdownError.notConnected }
        let plistData = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        var length = UInt32(plistData.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: lengthData + plistData, completion: .contentProcessed { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        let lengthResponse = try await receive(length: 4)
        let responseLength = lengthResponse.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let plistResponse = try await receive(length: Int(responseLength))
        guard let responseDict = try PropertyListSerialization.propertyList(from: plistResponse, options: [], format: nil) as? [String: Any] else {
            throw LockdownError.invalidResponse
        }
        return responseDict
    }
    
    private func receive(length: Int) async throws -> Data {
        guard let connection = connection else { throw LockdownError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            var acc = Data()
            func recv() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: length - acc.count) { data, _, isComplete, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    if let data = data { acc.append(data) }
                    if acc.count >= length {
                        continuation.resume(returning: acc.prefix(length))
                    } else if isComplete {
                        continuation.resume(throwing: LockdownError.incompleteData)
                    } else {
                        recv()
                    }
                }
            }
            recv()
        }
    }
    
    /// 啟動服務
    public func startService(_ serviceName: String) async throws -> (port: UInt16, sslEnabled: Bool) {
        var req: [String: Any] = ["Label": "PaxStore", "Request": "StartService", "Service": serviceName]
        if let sid = sessionID { req["SessionID"] = sid }
        let response = try await sendPlist(req)
        guard let result = response["Result"] as? String, result == "Success",
              let portRaw = response["Port"] as? Int ?? (response["Port"] as? UInt16).map({ Int($0) }) else {
            throw LockdownError.serviceStartFailed(serviceName)
        }
        let sslEnabled = (response["EnableServiceSSL"] as? Bool) ?? false
        return (UInt16(portRaw), sslEnabled)
    }
    
    /// 配對用的客戶端身份（給需要 SSL 的服務用）
    public var identity: SecIdentity? { pairIdentity }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

public enum LockdownError: Error, LocalizedError {
    case invalidPairingFile
    case missingCredentials
    case notConnected
    case connectionCancelled
    case invalidResponse
    case incompleteData
    case serviceStartFailed(String)
    case tlsSetupFailed(String)
    case handshakeFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidPairingFile: return "配對檔無效"
        case .missingCredentials: return "配對檔缺少證書"
        case .notConnected: return "未連接"
        case .connectionCancelled: return "連接已取消"
        case .invalidResponse: return "回應無效"
        case .incompleteData: return "數據不完整"
        case .serviceStartFailed(let s): return "啟動服務失敗: \(s)"
        case .tlsSetupFailed(let s): return "TLS 設置失敗: \(s)"
        case .handshakeFailed(let s): return "握手失敗: \(s)"
        }
    }
}
