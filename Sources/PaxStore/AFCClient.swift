import Foundation
import Security

/// AFC 協議客戶端（上傳 IPA 到 /PublicStaging/）
/// 使用 raw socket + SecureTransport（與 LockdownClient 相同的 TLS 寫法）
public class AFCClient {
    private var socketFD: Int32 = -1
    private var sslContext: SSLContext?
    private var useSSL = false
    private let host: String
    private var packetNum: UInt64 = 0
    
    private static let errWouldBlock: OSStatus = -9803
    private static let errServerAuthCompleted: OSStatus = -9841
    
    // AFC 操作碼
    private let OP_STATUS: UInt64 = 0x01
    private let OP_DATA: UInt64 = 0x02
    private let OP_WRITE: UInt64 = 0x05
    private let OP_OPEN: UInt64 = 0x11
    private let OP_CLOSE: UInt64 = 0x12
    
    // 文件打開模式
    private let FOPEN_WR: UInt64 = 0x04
    
    public init(host: String) {
        self.host = host
    }
    
    private static let sslReadFunc: SSLReadFunc = { connection, data, dataLength in
        let fd = Int32(Int(bitPattern: connection))
        let n = recv(fd, data, dataLength.pointee, 0)
        if n > 0 {
            dataLength.pointee = n
            return errSecSuccess
        } else if n == 0 {
            dataLength.pointee = 0
            return errSecIO
        } else {
            dataLength.pointee = 0
            return (errno == EAGAIN || errno == EWOULDBLOCK) ? AFCClient.errWouldBlock : errSecIO
        }
    }
    
    private static let sslWriteFunc: SSLWriteFunc = { connection, data, dataLength in
        let fd = Int32(Int(bitPattern: connection))
        let n = send(fd, data, dataLength.pointee, 0)
        if n > 0 {
            dataLength.pointee = n
            return errSecSuccess
        } else {
            dataLength.pointee = 0
            return (errno == EAGAIN || errno == EWOULDBLOCK) ? AFCClient.errWouldBlock : errSecIO
        }
    }
    
    /// 連接到 AFC 服務端口
    public func connect(port: UInt16, useSSL: Bool, identity: SecIdentity? = nil) async throws {
        self.useSSL = useSSL
        
        // 創建 TCP socket
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw AFCError.connectionFailed }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let r = host.withCString { cstr -> Int32 in
            var inAddr = in_addr()
            if inet_pton(AF_INET, cstr, &inAddr) == 1 {
                addr.sin_addr = inAddr
                return withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return -1
        }
        guard r == 0 else {
            close(socketFD)
            socketFD = -1
            throw AFCError.connectionFailed
        }
        
        // 如果需要 SSL，做 SecureTransport 握手（與 LockdownClient 相同寫法）
        if useSSL {
            guard let id = identity else { throw AFCError.tlsFailed("無客戶端身份") }
            try upgradeToTLS(identity: id)
        }
    }
    
    private func upgradeToTLS(identity: SecIdentity) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw AFCError.tlsFailed("SSLContext 創建失敗")
        }
        self.sslContext = ctx
        let connRef = unsafeBitCast(Int(socketFD), to: SSLConnectionRef.self)
        var status = SSLSetConnection(ctx, connRef)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetConnection: \(status)") }
        status = SSLSetIOFuncs(ctx, Self.sslReadFunc, Self.sslWriteFunc)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetIOFuncs: \(status)") }
        status = SSLSetCertificate(ctx, [identity] as CFArray)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetCertificate: \(status)") }
        status = SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetSessionOption: \(status)") }
        repeat {
            status = SSLHandshake(ctx)
            if status == Self.errServerAuthCompleted {
                continue
            }
        } while status == Self.errWouldBlock || status == Self.errServerAuthCompleted
        guard status == errSecSuccess else {
            throw AFCError.tlsFailed("TLS 握手失敗: \(status)")
        }
    }
    
    private func sendBytes(_ data: Data) throws {
        if useSSL {
            guard let ctx = sslContext else { throw AFCError.notConnected }
            var sent = 0
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                while sent < data.count {
                    var processed = 0
                    let status = SSLWrite(ctx, base.advanced(by: sent), data.count - sent, &processed)
                    if status != errSecSuccess && status != Self.errWouldBlock {
                        throw AFCError.tlsFailed("SSLWrite: \(status)")
                    }
                    sent += processed
                    if processed == 0 && status == Self.errWouldBlock { continue }
                }
            }
        } else {
            var sent = 0
            try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                while sent < data.count {
                    let n = send(socketFD, base.advanced(by: sent), data.count - sent, 0)
                    if n <= 0 { throw AFCError.sendFailed }
                    sent += n
                }
            }
        }
    }
    
    private func recvBytes(length: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        if useSSL {
            guard let ctx = sslContext else { throw AFCError.notConnected }
            while result.count < length {
                var buf = [UInt8](repeating: 0, count: length - result.count)
                var processed = 0
                let status = buf.withUnsafeMutableBytes { ptr -> OSStatus in
                    guard let base = ptr.baseAddress else { return errSecIO }
                    return SSLRead(ctx, base, length - result.count, &processed)
                }
                if status != errSecSuccess && status != Self.errWouldBlock {
                    throw AFCError.recvFailed("SSLRead: \(status)")
                }
                if processed > 0 {
                    result.append(contentsOf: buf.prefix(processed))
                } else if status == errSecSuccess {
                    throw AFCError.incompleteData
                }
            }
        } else {
            while result.count < length {
                var buf = [UInt8](repeating: 0, count: length - result.count)
                let n = buf.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return recv(socketFD, base, length - result.count, 0)
                }
                if n > 0 {
                    result.append(contentsOf: buf.prefix(n))
                } else {
                    throw AFCError.incompleteData
                }
            }
        }
        return result
    }
    
    private func nextNum() -> UInt64 {
        packetNum += 1
        return packetNum
    }
    
    /// 發送 AFC 包並接收回應
    private func transact(op: UInt64, payload: Data, opName: String = "未知") async throws -> (op: UInt64, data: Data) {
        let num = nextNum()
        
        var header = Data()
        header.append("CFA6LPAA".data(using: .ascii)!)
        var totalLen = UInt64(40 + payload.count).littleEndian
        header.append(Data(bytes: &totalLen, count: 8))
        var opLE = op.littleEndian
        header.append(Data(bytes: &opLE, count: 8))
        var numLE = num.littleEndian
        header.append(Data(bytes: &numLE, count: 8))
        var dataLen = UInt64(payload.count).littleEndian
        header.append(Data(bytes: &dataLen, count: 8))
        
        try sendBytes(header + payload)
        
        let respHeader: Data
        do {
            respHeader = try recvBytes(length: 40)
        } catch {
            throw AFCError.operationFailed("\(opName): 讀回應頭失敗: \(error)")
        }
        guard respHeader.prefix(8) == "CFA6LPAA".data(using: .ascii)! else {
            throw AFCError.invalidResponse
        }
        let respTotalLen = respHeader[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respOp = respHeader[16..<24].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        let respDataLen = respHeader[32..<40].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        var respData = Data()
        let toRead = Int(respTotalLen) - 40
        if toRead > 0 {
            do {
                respData = try recvBytes(length: toRead)
            } catch {
                throw AFCError.operationFailed("\(opName): 讀回應體失敗: \(error)")
            }
        }
        return (respOp, respData.prefix(Int(respDataLen)))
    }
    
    /// 上傳文件到設備
    ///   - localURL: 本地 IPA 路徑
    ///   - remotePath: 設備上的路徑（如 /PublicStaging/app.ipa）
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        
        // 1. OPEN
        var openPayload = Data()
        var mode = FOPEN_WR.littleEndian
        openPayload.append(Data(bytes: &mode, count: 8))
        openPayload.append(remotePath.data(using: .utf8)!)
        openPayload.append(0x00)
        
        let (openOp, openData) = try await transact(op: OP_OPEN, payload: openPayload, opName: "OPEN")
        guard openOp == OP_DATA, openData.count >= 8 else {
            throw AFCError.openFailed(remotePath)
        }
        let handle = openData.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        // 2. WRITE 分塊
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        let chunkSize = 32 * 1024  // 32KB（VPN 下大包易斷）
        var sent: Int64 = 0
        
        while sent < totalSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            
            var writePayload = Data()
            var hLE = handle.littleEndian
            writePayload.append(Data(bytes: &hLE, count: 8))
            writePayload.append(chunk)
            
            let (writeOp, _) = try await transact(op: OP_WRITE, payload: writePayload, opName: "WRITE")
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
        let (closeOp, _) = try await transact(op: OP_CLOSE, payload: closePayload, opName: "CLOSE")
        guard closeOp == OP_STATUS else {
            throw AFCError.closeFailed
        }
    }
    
    public func disconnect() {
        if let ctx = sslContext {
            SSLClose(ctx)
            self.sslContext = nil
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
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
