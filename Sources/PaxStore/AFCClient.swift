import Foundation
import Network

/// AFC 協議客戶端（上傳 IPA 到 /PublicStaging/）
public class AFCClient {
    private var connection: NWConnection?
    private let host: String
    private var packetNum: UInt64 = 0
    
    // AFC 操作碼
    private let OP_STATUS: UInt64 = 0x01
    private let OP_DATA: UInt64 = 0x02
    private let OP_WRITE: UInt64 = 0x05
    private let OP_OPEN: UInt64 = 0x11
    private let OP_CLOSE: UInt64 = 0x12
    
    // 文件打開模式
    private let FOPEN_WR: UInt64 = 0x04  // 寫（創建）
    
    public init(host: String) {
        self.host = host
    }
    
    /// 連接到 AFC 服務端口
    public func connect(port: UInt16, useSSL: Bool, identity: SecIdentity? = nil) async throws {
        let params: NWParameters
        if useSSL {
            let tlsOptions = NWProtocolTLS.Options()
            if let id = identity {
                sec_protocol_options_set_local_identity(
                    tlsOptions.securityProtocolOptions,
                    sec_identity_create(id)!
                )
            }
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, .global())
            params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
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
                    continuation.resume(throwing: AFCError.connectionFailed)
                default: break
                }
            }
            connection?.start(queue: .global())
        }
    }
    
    private func nextNum() -> UInt64 {
        packetNum += 1
        return packetNum
    }
    
    /// 發送 AFC 包並接收回應
    private func transact(op: UInt64, payload: Data) async throws -> (op: UInt64, data: Data) {
        guard let connection = connection else { throw AFCError.notConnected }
        let num = nextNum()
        
        // 構造包頭（40 字節，小端）
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)  // magic
        var totalLen = UInt64(40 + payload.count).littleEndian
        header.append(Data(bytes: &totalLen, count: 8))
        var opLE = op.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var dataLen = UInt64(payload.count).littleEndian
        header.append(Data(bytes: &dataLen, count: 8))
        
        let packet = header + payload
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        
        // 接收回應頭
        let respHeader = try await receive(length: 40)
        guard respHeader.prefix(8) == "CFA6LPAA".data(using: .ascii)! else {
            throw AFCError.invalidResponse
        }
        let respTotalLen = respHeader[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respOp = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        // let respNum = respHeader[24..<32]...
        let respDataLen = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        var respData = Data()
        let toRead = Int(respTotalLen) - 40
        if toRead > 0 {
            respData = try await receive(length: toRead)
        }
        // dataLen 是 payload 中的數據長度，respData 包含它
        return (respOp, respData.prefix(Int(respDataLen)))
    }
    
    private func receive(length: Int) async throws -> Data {
        guard let connection = connection else { throw AFCError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            var acc = Data()
            func recv() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: length - acc.count) { data, _, isComplete, error in
                    if let error = error { continuation.resume(throwing: error); return }
                    if let data = data { acc.append(data) }
                    if acc.count >= length {
                        continuation.resume(returning: acc.prefix(length))
                    } else if isComplete {
                        continuation.resume(throwing: AFCError.incompleteData)
                    } else {
                        recv()
                    }
                }
            }
            recv()
        }
    }
    
    /// 上傳文件到設備
    /// - Parameters:
    ///   - localURL: 本地文件
    ///   - remotePath: 設備上的路徑（如 /PublicStaging/app.ipa）
    ///   - progress: 進度回調 (已傳字節, 總字節)
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        
        // 1. OPEN
        var openPayload = Data()
        // mode (u64) + path (null-terminated string)
        var mode = FOPEN_WR.littleEndian
        openPayload.append(Data(bytes: &mode, count: 8))
        openPayload.append(remotePath.data(using: .utf8)!)
        openPayload.append(0x00)
        
        let (openOp, openData) = try await transact(op: OP_OPEN, payload: openPayload)
        guard openOp == OP_DATA, openData.count >= 8 else {
            throw AFCError.openFailed(remotePath)
        }
        let handle = openData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        // 2. WRITE 分塊
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        let chunkSize = 1024 * 1024  // 1MB
        var sent: Int64 = 0
        
        while sent < totalSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            
            var writePayload = Data()
            var hLE = handle.littleEndian
            writePayload.append(Data(bytes: &hLE, count: 8))
            writePayload.append(chunk)
            
            let (writeOp, _) = try await transact(op: OP_WRITE, payload: writePayload)
            guard writeOp == OP_STATUS else {
                throw AFCError.writeFailed
            }
            
            sent += Int64(chunk.count)
            progress(sent, totalSize)
        }
        
        // 3. CLOSE
        var closePayload = Data()
        var hLE2 = handle.littleEndian
        closePayload.append(Data(bytes: &hLE2, count: 8))
        let (closeOp, _) = try await transact(op: OP_CLOSE, payload: closePayload)
        guard closeOp == OP_STATUS else {
            throw AFCError.closeFailed
        }
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

public enum AFCError: Error, LocalizedError {
    case notConnected
    case connectionFailed
    case invalidResponse
    case incompleteData
    case openFailed(String)
    case writeFailed
    case closeFailed
    
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "AFC 未連接"
        case .connectionFailed: return "AFC 連接失敗"
        case .invalidResponse: return "AFC 回應無效"
        case .incompleteData: return "AFC 數據不完整"
        case .openFailed(let p): return "AFC 打開文件失敗: \(p)"
        case .writeFailed: return "AFC 寫入失敗"
        case .closeFailed: return "AFC 關閉失敗"
        }
    }
}
