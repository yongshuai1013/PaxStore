import Foundation

/// 用 Rust idevice-ffi 實現的 AFC 客戶端
/// FFI 是同步阻塞的，必須在後台線程調用
public class RustAFCClient {
    private var provider: OpaquePointer?
    private var afcClient: OpaquePointer?

    public init() {}

    deinit { disconnect() }

    private func checkError(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ context: String) throws {
        guard let e = err else { return }
        let code = e.pointee.code
        let msg: String
        if let cmsg = e.pointee.message {
            msg = String(cString: cmsg)
        } else {
            msg = "unknown"
        }
        idevice_error_free(e)
        throw RustAFCError.ffiFailed("\(context): [\(code)] \(msg)")
    }

    public func connect(pairingFileURL: URL, host: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let plistData = try Data(contentsOf: pairingFileURL)
            var pf: OpaquePointer?
            try plistData.withUnsafeBytes { ptr in
                let err = idevice_pairing_file_from_bytes(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    plistData.count,
                    &pf)
                try self.checkError(err, "載入配對檔")
            }
            guard let pairingFile = pf else {
                throw RustAFCError.ffiFailed("配對檔句柄為空")
            }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(62078).bigEndian
            host.withCString { cstr in
                inet_pton(AF_INET, cstr, &addr.sin_addr)
            }
            var prov: OpaquePointer?
            let err2 = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    idevice_tcp_provider_new(sptr, pairingFile, "PaxStore", &prov)
                }
            }
            try self.checkError(err2, "創建 TCP provider")
            guard let p = prov else {
                throw RustAFCError.ffiFailed("provider 句柄為空")
            }
            self.provider = p
            var afc: OpaquePointer?
            let err3 = afc_client_connect(p, &afc)
            try self.checkError(err3, "AFC 連接")
            guard let a = afc else {
                throw RustAFCError.ffiFailed("AFC 句柄為空")
            }
            self.afcClient = a
        }.value
    }

    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let afc = afcClient else { throw RustAFCError.notConnected }
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0
        try await Task.detached(priority: .userInitiated) {
            var fh: OpaquePointer?
            let errOpen = remotePath.withCString { cstr in
                afc_file_open(afc, cstr, AfcWrOnly, &fh)
            }
            try self.checkError(errOpen, "AFC OPEN \(remotePath)")
            guard let fileHandle = fh else {
                throw RustAFCError.ffiFailed("文件句柄為空")
            }
            defer { let _ = afc_file_close(fileHandle) }
            let fh2 = try FileHandle(forReadingFrom: localURL)
            defer { try? fh2.close() }
            let chunkSize = 256 * 1024
            var sent: Int64 = 0
            while sent < totalSize {
                let chunk = fh2.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                try chunk.withUnsafeBytes { ptr in
                    let err = afc_file_write(fileHandle, ptr.baseAddress?.assumingMemoryBound(to: UInt8.self), chunk.count)
                    try self.checkError(err, "AFC WRITE")
                }
                sent += Int64(chunk.count)
                let s = sent
                await MainActor.run { progress(s, totalSize) }
            }
        }.value
    }

    public func disconnect() {
        if let a = afcClient { afc_client_free(a); afcClient = nil }
        if let p = provider { idevice_provider_free(p); provider = nil }
    }
}

public enum RustAFCError: Error, LocalizedError {
    case notConnected
    case ffiFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Rust AFC 未連接"
        case .ffiFailed(let s): return s
        }
    }
}
