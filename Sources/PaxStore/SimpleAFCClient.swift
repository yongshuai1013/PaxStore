import Foundation
import Network

/// 極簡 AFC 客戶端：Network.framework + 手動封包，用舊代碼驗證過的格式
public class SimpleAFCClient {
    private var connection: NWConnection?
    private var packetNum: UInt64 = 0
    public var log: [String] = []
    
    private let OP_OPEN: UInt64 = 0x0D
    private let OP_OPENRES: UInt64 = 0x0E
    private let FOPEN_WR: UInt64 = 0x04
    
    private func addLog(_ s: String) {
        log.append(s)
        print("[SimpleAFC] \(s)")
    }
    
    /// 連接 AFC（TLS + 客戶端證書）
    public func connect(host: String, port: UInt16, identity: SecIdentity) async throws {
        addLog("TCP+TLS 連接 \(host):\(port)")
        
        let tlsOptions = NWProtocolTLS.Options()
        let secOpts = tlsOptions.securityProtocolOptions
        // 設置客戶端證書
        let secId = sec_identity_create(identity as CFTypeRef)
        sec_protocol_options_set_local_identity(secOpts, secId)
        // 設置 SNI
        "Device".withCString { cstr in
            sec_protocol_options_set_tls_server_name(secOpts, cstr)
        }
        // 不驗證服務器證書（afcd 用自簽名）
        let verifyBlock: @convention(block) (sec_protocol_metadata_t, sec_trust_t, @escaping (Bool) -> Void) -> Void = { _, _, complete in
            complete(true)
        }
        sec_protocol_options_set_verify_block(secOpts, verifyBlock, DispatchQueue.global())
        
        let params = NWParameters(tls: tlsOptions)
        params.includePeerToPeer = true
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn
        
        return try await withCheckedThrowingContinuation { cont in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.addLog("TLS 握手成功")
                    cont.resume()
                case .failed(let err):
                    self.addLog("連接失敗: \(err)")
                    cont.resume(throwing: err)
                case .cancelled:
                    cont.resume(throwing: NSError(domain: "SimpleAFC", code: -1, userInfo: [NSLocalizedDescriptionKey: "連接取消"]))
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global())
        }
    }
    
    private func send(_ data: Data) async throws {
        guard let conn = connection else { throw NSError(domain: "SimpleAFC", code: -1, userInfo: nil) }
        return try await withCheckedThrowingContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }
    
    private func recv(length: Int) async throws -> Data {
        guard let conn = connection else { throw NSError(domain: "SimpleAFC", code: -1, userInfo: nil) }
        return try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, err in
                if let err = err {
                    cont.resume(throwing: err)
                } else if let data = data, data.count == length {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: NSError(domain: "SimpleAFC", code: -2, userInfo: [NSLocalizedDescriptionKey: "讀取長度不符"]))
                }
            }
        }
    }
    
    /// 測試 OPEN（只做 OPEN，不上傳）
    public func testOpen(path: String) async throws -> UInt64 {
        addLog("OPEN 測試: \(path)")
        
        let num = packetNum
        packetNum += 1
        
        var headerPayload = Data()
        var mode = FOPEN_WR.littleEndian
        headerPayload.append(Data(bytes: &mode, count: 8))
        headerPayload.append(path.data(using: .utf8)!)
        
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)
        var entireLen = UInt64(40 + headerPayload.count).littleEndian
        header.append(Data(bytes: &entireLen, count: 8))
        var hpLen = UInt64(40 + headerPayload.count).littleEndian
        header.append(Data(bytes: &hpLen, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var opLE = OP_OPEN.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        
        addLog("發送 OPEN 封包 (\(header.count + headerPayload.count) 字節)")
        try await send(header + headerPayload)
        
        addLog("等待回應...")
        let respHeader = try await recv(length: 40)
        
        guard respHeader.prefix(8) == "CFA6LPAA".data(using: .ascii)! else {
            throw NSError(domain: "SimpleAFC", code: -3, userInfo: [NSLocalizedDescriptionKey: "Magic 不符"])
        }
        
        let respOp = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        addLog("回應 op=0x\(String(format: "%02X", respOp))")
        
        guard respOp == OP_OPENRES else {
            throw NSError(domain: "SimpleAFC", code: -4, userInfo: [NSLocalizedDescriptionKey: "OPEN 被拒 (op=0x\(String(format: "%02X", respOp)))"])
        }
        
        let respHpLen = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let hpToRead = Int(respHpLen) - 40
        var handle: UInt64 = 0
        if hpToRead >= 8 {
            let hp = try await recv(length: hpToRead)
            handle = hp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }
        
        addLog("OPEN 成功，handle=\(handle)")
        return handle
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

extension SimpleAFCClient {
    private let OP_WRITE: UInt64 = 0x0B
    private let OP_WRITERES: UInt64 = 0x0C
    private let OP_CLOSE: UInt64 = 0x04
    
    /// 完整上傳（OPEN + WRITE + CLOSE）
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let handle = try await testOpen(path: remotePath)
        
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        let chunkSize = 32 * 1024
        var sent: Int64 = 0
        
        while sent < totalSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            
            // WRITE 封包
            let num = packetNum
            packetNum += 1
            
            var headerPayload = Data()
            var hLE = handle.littleEndian
            headerPayload.append(Data(bytes: &hLE, count: 8))
            
            var header = Data()
            header.append("CFA6LPAA".data(using: .ascii)!)
            var entireLen = UInt64(40 + headerPayload.count + chunk.count).littleEndian
            header.append(Data(bytes: &entireLen, count: 8))
            var hpLen = UInt64(40 + headerPayload.count).littleEndian
            header.append(Data(bytes: &hpLen, count: 8))
            var numLE = num.littleEndian
            header.append(Data(bytes: &numLE, count: 8))
            var opLE = OP_WRITE.littleEndian
            header.append(Data(bytes: &opLE, count: 8))
            
            try await send(header + headerPayload + chunk)
            
            // 讀回應
            let respHeader = try await recv(length: 40)
            let respOp = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            guard respOp == OP_WRITERES else {
                throw NSError(domain: "SimpleAFC", code: -5, userInfo: [NSLocalizedDescriptionKey: "WRITE 被拒"])
            }
            let respHpLen = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let respEntireLen = respHeader[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            let hpToRead = Int(respHpLen) - 40
            if hpToRead > 0 { _ = try await recv(length: hpToRead) }
            let pToRead = Int(respEntireLen) - Int(respHpLen)
            if pToRead > 0 { _ = try await recv(length: pToRead) }
            
            sent += Int64(chunk.count)
            progress(sent, totalSize)
        }
        
        // CLOSE
        let num = packetNum
        packetNum += 1
        var closeHp = Data()
        var hLE = handle.littleEndian
        closeHp.append(Data(bytes: &hLE, count: 8))
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)
        var entireLen = UInt64(40 + closeHp.count).littleEndian
        header.append(Data(bytes: &entireLen, count: 8))
        var hpLen = UInt64(40 + closeHp.count).littleEndian
        header.append(Data(bytes: &hpLen, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var opLE = OP_CLOSE.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        try await send(header + closeHp)
        _ = try await recv(length: 40)
        
        addLog("上傳完成")
    }
}
