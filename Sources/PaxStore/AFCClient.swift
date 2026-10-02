import Foundation
import Network
import Security

/// AFC 協議客戶端（上傳 IPA 到 /PublicStaging/）
/// 使用 Network.framework（NWConnection），TLS 行為可能與 SecureTransport 不同
public class AFCClient {
    private var connection: NWConnection?
    private var useSSL = false
    private let host: String
    private var packetNum: UInt64 = 0
    
    // AFC 操作碼（對照 idevice opcode.rs／libimobiledevice afc.h）
    private let OP_STATUS: UInt64 = 0x01
    private let OP_DATA: UInt64 = 0x02
    private let OP_OPEN: UInt64 = 0x0D      // FileOpen
    private let OP_OPENRES: UInt64 = 0x0E   // FileOpenRes
    private let OP_WRITE: UInt64 = 0x10     // Write (FileRefWrite)
    private let OP_CLOSE: UInt64 = 0x14     // FileClose
    
    // 文件打開模式（對照 idevice AfcFopenMode）
    private let FOPEN_WR: UInt64 = 0x04     // w+ O_RDWR | O_CREAT | O_TRUNC
    
    public init(host: String) {
        self.host = host
    }
    
    private func makeTLSOptions(identity: SecIdentity) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOpts = options.securityProtocolOptions
        // 強制 TLS 1.2（之前 SecureTransport 也是這麼設的）
        sec_protocol_options_set_min_tls_protocol_version(secOpts, .tlsv12)
        sec_protocol_options_set_max_tls_protocol_version(secOpts, .tlsv12)
        // SNI "Device"（對照 idevice）
        sec_protocol_options_set_tls_server_name(secOpts, "Device")
        // 客戶端證書（配對檔身份）
        let secId = sec_identity_create(identity as CFTypeRef)!
        sec_protocol_options_set_local_identity(secOpts, secId)
        // 接受任意服務器證書（對應之前的 breakOnServerAuth + continue）
        sec_protocol_options_set_verify_block(secOpts, { _, _, completion in
            completion(true)
        }, DispatchQueue.global())
        return options
    }
    
    /// 連接到 AFC 服務端口
    public func connect(port: UInt16, useSSL: Bool, identity: SecIdentity? = nil) async throws {
        // 給 afcd 1 秒啟動時間（之前加的延遲，保留）
        if !useSSL {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        self.useSSL = useSSL
        
        let params: NWParameters
        if useSSL {
            guard let id = identity else { throw AFCError.tlsFailed("無客戶端身份") }
            params = NWParameters(tls: makeTLSOptions(identity: id))
        } else {
            params = NWParameters.tcp
        }
        
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        self.connection = conn
        
        // 等待連接就緒（或失敗）
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                case .failed(let err):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: AFCError.tlsFailed("NWConnection 失敗: \(err)"))
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: AFCError.connectionFailed)
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global())
            // 超時保護：10 秒
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if !resumed {
                    resumed = true
                    conn.cancel()
                    cont.resume(throwing: AFCError.connectionFailed)
                }
            }
        }
    }
    
    private func sendBytes(_ data: Data) async throws {
        guard let conn = connection else { throw AFCError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: AFCError.sendFailed)
                } else {
                    cont.resume()
                }
            })
        }
    }
    
    private func recvBytes(length: Int) async throws -> Data {
        guard let conn = connection else { throw AFCError.notConnected }
        var result = Data()
        result.reserveCapacity(length)
        while result.count < length {
            let remaining = length - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, err in
                    if let err = err {
                        cont.resume(throwing: AFCError.recvFailed("\(err)"))
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: AFCError.incompleteData)
                    } else {
                        cont.resume(throwing: AFCError.incompleteData)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }
    
    private func nextNum() -> UInt64 {
        let num = packetNum
        packetNum += 1
        return num
    }
    
    /// 發送 AFC 包並接收回應（包頭 40 字節，對照 idevice packet.rs）
    private func transact(op: UInt64, headerPayload: Data, payload: Data, opName: String = "未知") async throws -> (op: UInt64, headerPayload: Data, payload: Data) {
        let num = nextNum()
        
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)
        var entireLen = UInt64(40 + headerPayload.count + payload.count).littleEndian
        header.append(Data(bytes: &entireLen, count: 8))
        var hpLen = UInt64(40 + headerPayload.count).littleEndian
        header.append(Data(bytes: &hpLen, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var opLE = op.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        
        try await sendBytes(header + headerPayload + payload)
        
        let respHeader: Data
        do {
            respHeader = try await recvBytes(length: 40)
        } catch {
            throw AFCError.operationFailed("\(opName): 讀回應頭失敗: \(error)")
        }
        guard respHeader.prefix(8) == "CFA6LPAA".data(using: .ascii)! else {
            throw AFCError.invalidResponse
        }
        let respEntireLen = respHeader[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respHpLen = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respOp = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        var respHp = Data()
        let hpToRead = Int(respHpLen) - 40
        if hpToRead > 0 {
            do {
                respHp = try await recvBytes(length: hpToRead)
            } catch {
                throw AFCError.operationFailed("\(opName): 讀回應頭負載失敗: \(error)")
            }
        }
        var respPayload = Data()
        let pToRead = Int(respEntireLen) - Int(respHpLen)
        if pToRead > 0 {
            do {
                respPayload = try await recvBytes(length: pToRead)
            } catch {
                throw AFCError.operationFailed("\(opName): 讀回應體失敗: \(error)")
            }
        }
        return (respOp, respHp, respPayload)
    }
    
    /// 上傳文件到設備（對照 idevice：FileOpen → Write → FileClose）
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        
        // 1. OPEN：header_payload = mode(8) + path（無 NUL，對照 idevice）
        var openHp = Data()
        var mode = FOPEN_WR.littleEndian
        openHp.append(Data(bytes: &mode, count: 8))
        openHp.append(remotePath.data(using: .utf8)!)
        
        let (openOp, openHpResp, _) = try await transact(op: OP_OPEN, headerPayload: openHp, payload: Data(), opName: "OPEN")
        guard openOp == OP_OPENRES, openHpResp.count >= 8 else {
            throw AFCError.openFailed("\(remotePath) (op=\(String(format: "0x%02X", openOp)))")
        }
        let handle = openHpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        // 2. WRITE 分塊
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        let chunkSize = 32 * 1024
        var sent: Int64 = 0
        
        while sent < totalSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            
            var writeHp = Data()
            var hLE = handle.littleEndian
            writeHp.append(Data(bytes: &hLE, count: 8))
            
            let (writeOp, writeHpResp, _) = try await transact(op: OP_WRITE, headerPayload: writeHp, payload: chunk, opName: "WRITE")
            let writeCode: UInt64 = writeHpResp.count >= 8 ? writeHpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian } : .max
            guard writeOp == OP_STATUS, writeCode == 0 else {
                throw AFCError.writeFailed
            }
            
            sent += Int64(chunk.count)
            progress(sent, totalSize)
        }
        
        // 3. CLOSE
        var closeHp = Data()
        var hLE2 = handle.littleEndian
        closeHp.append(Data(bytes: &hLE2, count: 8))
        let (closeOp, _, _) = try await transact(op: OP_CLOSE, headerPayload: closeHp, payload: Data(), opName: "CLOSE")
        guard closeOp == OP_STATUS else {
            throw AFCError.closeFailed
        }
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
        useSSL = false
    }
}

public enum AFCError: Error, LocalizedError {
    case notConnected
    case connectionFailed
    case sendFailed
    case recvFailed(String)
    case tlsFailed(String)
    case invalidResponse
    case incompleteData
    case operationFailed(String)
    case openFailed(String)
    case writeFailed
    case closeFailed
    
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "AFC 未連接"
        case .connectionFailed: return "AFC 連接失敗"
        case .sendFailed: return "AFC 發送失敗"
        case .recvFailed(let s): return "AFC 接收失敗: \(s)"
        case .tlsFailed(let s): return "AFC TLS 失敗: \(s)"
        case .invalidResponse: return "AFC 回應無效"
        case .incompleteData: return "AFC 數據不完整"
        case .operationFailed(let s): return s
        case .openFailed(let p): return "AFC 打開失敗: \(p)"
        case .writeFailed: return "AFC 寫入失敗"
        case .closeFailed: return "AFC 關閉失敗"
        }
    }
}
