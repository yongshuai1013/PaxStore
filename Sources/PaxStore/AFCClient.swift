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
        // 對照 idevice：SNI 填 "Device"（之前誤刪，這次配合 TLS 1.2 重測）
        status = SSLSetPeerDomainName(ctx, "Device", 6)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetPeerDomainName: \(status)") }
        // afcd 可能不吃 TLS 1.3 ClientHello，強制只用 TLS 1.2（對照 KonnectMac 寫法）
        status = SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetProtocolVersionMin: \(status)") }
        status = SSLSetProtocolVersionMax(ctx, .tlsProtocol12)
        guard status == errSecSuccess else { throw AFCError.tlsFailed("SSLSetProtocolVersionMax: \(status)") }
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
    /// 包頭（40 字節，對照 idevice packet.rs）：
    ///   offset 0: magic "CFA6LPAA" (u64)
    ///   offset 8: entire_len = 40 + headerPayload + payload (u64 LE)
    ///   offset 16: header_payload_len = 40 + headerPayload (u64 LE)
    ///   offset 24: packet_num (u64 LE)
    ///   offset 32: operation (u64 LE)
    /// 回應同樣結構；header_payload 先讀 (header_payload_len-40)，再讀 (entire_len-header_payload_len)
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
        
        try sendBytes(header + headerPayload + payload)
        
        let respHeader: Data
        do {
            respHeader = try recvBytes(length: 40)
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
                respHp = try recvBytes(length: hpToRead)
            } catch {
                throw AFCError.operationFailed("\(opName): 讀回應頭負載失敗: \(error)")
            }
        }
        var respPayload = Data()
        let pToRead = Int(respEntireLen) - Int(respHpLen)
        if pToRead > 0 {
            do {
                respPayload = try recvBytes(length: pToRead)
            } catch {
                throw AFCError.operationFailed("\(opName): 讀回應體失敗: \(error)")
            }
        }
        return (respOp, respHp, respPayload)
    }
    
    /// 上傳文件到設備（對照 idevice：FileOpen → Write → FileClose）
    ///   - localURL: 本地 IPA 路徑
    ///   - remotePath: 設備上的路徑（如 PublicStaging/app.ipa，無前導斜線）
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        
        // 1. OPEN：header_payload = mode(8) + path + NUL
        //    （libimobiledevice 經典實現帶 NUL 結尾；idevice 沒加但 iOS 15 的 afcd 要求）
        //    回應操作碼為 FileOpenRes(0x0E)，handle 在回應的 header_payload 前 8 字節
        var openHp = Data()
        var mode = FOPEN_WR.littleEndian
        openHp.append(Data(bytes: &mode, count: 8))
        openHp.append(remotePath.data(using: .utf8)!)
        openHp.append(0x00)
        
        let (openOp, openHpResp, _) = try await transact(op: OP_OPEN, headerPayload: openHp, payload: Data(), opName: "OPEN")
        guard openOp == OP_OPENRES, openHpResp.count >= 8 else {
            throw AFCError.openFailed("\(remotePath) (op=\(String(format: "0x%02X", openOp)))")
        }
        let handle = openHpResp.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        
        // 2. WRITE 分塊：header_payload = handle(8)，payload = 數據塊；回應為 STATUS(0=成功)
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }
        
        let chunkSize = 32 * 1024  // 32KB（VPN 下大包易斷）
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
        
        // 3. CLOSE：header_payload = handle(8)；回應為 STATUS
        var closeHp = Data()
        var hLE2 = handle.littleEndian
        closeHp.append(Data(bytes: &hLE2, count: 8))
        let (closeOp, _, _) = try await transact(op: OP_CLOSE, headerPayload: closeHp, payload: Data(), opName: "CLOSE")
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

