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
    /// 從配對檔建立 SecIdentity（經 Keychain）
    private func makeIdentity(hostCertPEM: String, hostKeyPEM: String) throws -> SecIdentity {
        guard let certDER = derFromPEM(hostCertPEM) else { throw LockdownError.missingCredentials }
        guard let keyDER = derFromPEM(hostKeyPEM) else { throw LockdownError.missingCredentials }
        
        let pemHeader = hostKeyPEM.components(separatedBy: .newlines).first(where: { $0.hasPrefix("-----") }) ?? "無PEM頭"
        let derHex = keyDER.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        
        // 驗證 PKCS#8 結構
        var diag: [String] = ["[\(pemHeader)] DER \(keyDER.count)字節 頭:\(derHex)"]
        guard let pkcs1Range = validatePKCS8(keyDER, diag: &diag) else {
            throw LockdownError.tlsSetupFailed("私鑰結構驗證失敗\n" + diag.joined(separator: "\n"))
        }
        diag.append("PKCS#8 結構有效，內層 PKCS#1 \(pkcs1Range.count)字節")
        
        // 先清掉舊的
        let delKey: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: "PaxStorePairing".data(using: .utf8)!]
        SecItemDelete(delKey as CFDictionary)
        let delCert: [String: Any] = [kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "PaxStorePairing"]
        SecItemDelete(delCert as CFDictionary)
        
        // 導入私鑰（明確指定 2048 位）
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var err: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyDER as CFData, keyAttrs as CFDictionary, &err) else {
            let msg = err?.takeRetainedValue().localizedDescription ?? "未知錯誤"
            throw LockdownError.tlsSetupFailed("私鑰導入失敗: \(msg)\n" + diag.joined(separator: "\n"))
        }
        diag.append("私鑰導入成功")
        
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
        
        // 取 Identity
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: "PaxStorePairing",
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            let q2: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecValueRef as String: cert,
                kSecReturnRef as String: true,
            ]
            status = SecItemCopyMatching(q2 as CFDictionary, &item)
        }
        guard status == errSecSuccess, let identity = item as! SecIdentity? else {
            throw LockdownError.tlsSetupFailed("取 SecIdentity 失敗: \(status)")
        }
        return identity
    }
    
    /// 驗證 PKCS#8 結構，返回內層 PKCS#1 的範圍
    private func validatePKCS8(_ data: Data, diag: inout [String]) -> Range<Int>? {
        let bytes = [UInt8](data)
        var pos = 0
        
        // 外層 SEQUENCE
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("外層不是 SEQUENCE"); return nil }
        pos += 1
        guard let (seqLen, seqLenBytes) = readDERLength(bytes, pos) else { diag.append("外層長度解析失敗"); return nil }
        pos += seqLenBytes
        if seqLen != bytes.count - pos {
            diag.append("外層長度不匹配: 聲稱\(seqLen)，實際\(bytes.count - pos)")
            return nil
        }
        diag.append("外層 SEQUENCE 長度\(seqLen) ✓")
        
        // INTEGER 0 (version)
        guard pos + 3 <= bytes.count && bytes[pos] == 0x02 && bytes[pos+1] == 0x01 && bytes[pos+2] == 0x00 else {
            diag.append("版本不是 INTEGER 0"); return nil
        }
        pos += 3
        diag.append("版本 INTEGER 0 ✓")
        
        // AlgorithmIdentifier SEQUENCE
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("算法標識不是 SEQUENCE"); return nil }
        pos += 1
        guard let (algLen, algLenBytes) = readDERLength(bytes, pos) else { diag.append("算法長度解析失敗"); return nil }
        pos += algLenBytes
        let algEnd = pos + algLen
        // OID rsaEncryption
        let expectedOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        guard pos + expectedOID.count <= bytes.count && Array(bytes[pos..<(pos+expectedOID.count)]) == expectedOID else {
            diag.append("OID 不是 rsaEncryption"); return nil
        }
        pos += expectedOID.count
        // NULL
        guard pos + 2 <= bytes.count && bytes[pos] == 0x05 && bytes[pos+1] == 0x00 else {
            diag.append("算法參數不是 NULL"); return nil
        }
        pos += 2
        if pos != algEnd { diag.append("算法標識有多餘字節"); return nil }
        diag.append("算法 rsaEncryption ✓")
        
        // OCTET STRING (內層 PKCS#1)
        guard pos < bytes.count && bytes[pos] == 0x04 else { diag.append("私鑰不是 OCTET STRING"); return nil }
        pos += 1
        guard let (octLen, octLenBytes) = readDERLength(bytes, pos) else { diag.append("OCTET長度解析失敗"); return nil }
        pos += octLenBytes
        let octEnd = pos + octLen
        guard octEnd == bytes.count else {
            diag.append("OCTET STRING 長度不匹配: 聲稱\(octLen)，剩餘\(bytes.count - pos)")
            return nil
        }
        diag.append("OCTET STRING 長度\(octLen) ✓")
        
        // 驗證內層是 PKCS#1 (SEQUENCE)
        guard pos < bytes.count && bytes[pos] == 0x30 else { diag.append("內層不是 SEQUENCE"); return nil }
        let innerSeqStart = pos
        pos += 1
        guard let (innerLen, innerLenBytes) = readDERLength(bytes, pos) else { diag.append("內層長度解析失敗"); return nil }
        pos += innerLenBytes
        let innerEnd = pos + innerLen
        guard innerEnd == octEnd else {
            diag.append("內層長度不匹配: 聲稱\(innerLen)，實際\(octEnd - pos)")
            return nil
        }
        diag.append("內層 SEQUENCE 長度\(innerLen) ✓")
        
        // PKCS#1 應有 9 個 INTEGER: version, n, e, d, p, q, dp, dq, qinv
        let names = ["版本", "n(模數)", "e(公鑰指數)", "d(私鑰指數)", "p", "q", "dp", "dq", "qinv"]
        var intCount = 0
        var nBits = 0
        while pos < innerEnd && intCount < 9 {
            guard pos < bytes.count && bytes[pos] == 0x02 else {
                diag.append("第\(intCount)個不是 INTEGER (tag=\(pos < bytes.count ? String(format:"%02X", bytes[pos]) : "越界"))")
                return nil
            }
            pos += 1
            guard let (ilen, ilenBytes) = readDERLength(bytes, pos) else {
                diag.append("第\(intCount)個 INTEGER 長度解析失敗"); return nil
            }
            pos += ilenBytes
            guard pos + ilen <= bytes.count else {
                diag.append("第\(intCount)個 INTEGER 超出範圍"); return nil
            }
            // 檢查 INTEGER 是否為負數（首字節最高位為1且無前導零）
            let firstByte = bytes[pos]
            let isNegative = (firstByte & 0x80) != 0
            let name = intCount < names.count ? names[intCount] : "未知"
            if intCount == 1 { nBits = ilen * 8 }  // n 的字節數估算位數
            if isNegative {
                diag.append("第\(intCount)個 [\(name)] 長度\(ilen) 為負數 ✗")
            } else {
                diag.append("第\(intCount)個 [\(name)] 長度\(ilen) ✓")
            }
            pos += ilen
            intCount += 1
        }
        if intCount != 9 {
            diag.append("INTEGER 個數不對: \(intCount) (應為9)")
            return nil
        }
        if pos != innerEnd {
            diag.append("內層有多餘字節: \(innerEnd - pos)")
            return nil
        }
        diag.append("PKCS#1 9個INTEGER齊全，n約\(nBits)位 ✓")
        
        return innerSeqStart..<octEnd
    }
    
    /// 讀取 DER 長度編碼，返回 (長度, 佔用字節數)
    private func readDERLength(_ bytes: [UInt8], _ pos: Int) -> (Int, Int)? {
        guard pos < bytes.count else { return nil }
        let b = bytes[pos]
        if b < 0x80 { return (Int(b), 1) }
        let count = Int(b & 0x7F)
        guard count > 0 && count <= 4 && pos + 1 + count <= bytes.count else { return nil }
        var len = 0
        for i in 0..<count {
            len = (len << 8) | Int(bytes[pos + 1 + i])
        }
        return (len, 1 + count)
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
