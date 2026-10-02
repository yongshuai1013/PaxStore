import Foundation

/// 用 Rust idevice-ffi 實現的 AFC 客戶端（替代 SwiftNIO 版）
/// FFI 是同步阻塞的，必須在後台線程調用
public class RustAFCClient {
    private var provider: OpaquePointer?  // IdeviceProviderHandle*
    private var afcClient: OpaquePointer? // AfcClientHandle*

    public init() {}

    deinit {
        disconnect()
    }

    /// 檢查 FFI 錯誤，轉為 Swift Error
    private func checkError(_ err: OpaquePointer?, _ context: String) throws {
        guard let e = err else { return } // NULL = 成功
        // IdeviceFfiError { code: i32, sub_code: i32, message: *const c_char }
        let code = e.load(as: Int32.self)
        let msgPtr = e.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self)
        let msg = msgPtr.map { String(cString: $0) } ?? "unknown"
        idevice_error_free(e)
        throw RustAFCError.ffiFailed("\(context): [\(code)] \(msg)")
    }

    /// 連接：pairingFileURL 是配對檔 plist，host 如 "10.7.0.1"
    public func connect(pairingFileURL: URL, host: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            // 1. 讀配對檔
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

            // 2. 建 sockaddr_in
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(62078).bigEndian // lockdownd 端口（provider 內部會處理）
            host.withCString { cstr in
                inet_pton(AF_INET, cstr, &addr.sin_addr)
            }

            // 3. 創建 TCP provider（會 consume pairingFile）
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

            // 4. 連接 AFC（內部做 StartService + TLS）
            var afc: OpaquePointer?
            let err3 = afc_client_connect(p, &afc)
            try self.checkError(err3, "AFC 連接")
            guard let a = afc else {
                throw RustAFCError.ffiFailed("AFC 句柄為空")
            }
            self.afcClient = a
        }.value
    }

    /// 上傳文件到 /PublicStaging/
    public func uploadFile(localURL: URL, remotePath: String, progress: @escaping (Int64, Int64) -> Void) async throws {
        guard let afc = afcClient else { throw RustAFCError.notConnected }
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalSize = (attrs[.size] as? Int64) ?? 0

        try await Task.detached(priority: .userInitiated) {
            // OPEN
            var fh: OpaquePointer?
            let pathC = remotePath.cString(using: .utf8)!
            let errOpen = pathC.withUnsafeBufferPointer { ptr in
                afc_file_open(afc, ptr.baseAddress, 3 /* AfcWrOnly */, &fh)
            }
            try self.checkError(errOpen, "AFC OPEN \(remotePath)")
            guard let fileHandle = fh else {
                throw RustAFCError.ffiFailed("文件句柄為空")
            }
            defer {
                let _ = afc_file_close(fileHandle)
            }

            // WRITE 循環
            let fileHandle2 = try FileHandle(forReadingFrom: localURL)
            defer { try? fileHandle2.close() }
            let chunkSize = 256 * 1024
            var sent: Int64 = 0
            while sent < totalSize {
                let chunk = fileHandle2.readData(ofLength: chunkSize)
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
        if let a = afcClient {
            afc_client_free(a)
            afcClient = nil
        }
        if let p = provider {
            idevice_provider_free(p)
            provider = nil
        }
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

// MARK: - C FFI 聲明（對應 idevice.h）
// 這些函數由 IDeviceFFI.xcframework 提供

@_silgen_name("idevice_error_free")
func idevice_error_free(_ err: OpaquePointer?)

@_silgen_name("idevice_pairing_file_from_bytes")
func idevice_pairing_file_from_bytes(
    _ data: UnsafePointer<UInt8>?,
    _ size: Int,
    _ out: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer?

@_silgen_name("idevice_pairing_file_free")
func idevice_pairing_file_free(_ pf: OpaquePointer?)

@_silgen_name("idevice_tcp_provider_new")
func idevice_tcp_provider_new(
    _ addr: UnsafePointer<sockaddr>?,
    _ pf: OpaquePointer?,
    _ label: UnsafePointer<CChar>?,
    _ out: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer?

@_silgen_name("idevice_provider_free")
func idevice_provider_free(_ p: OpaquePointer?)

@_silgen_name("afc_client_connect")
func afc_client_connect(
    _ provider: OpaquePointer?,
    _ out: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer?

@_silgen_name("afc_client_free")
func afc_client_free(_ c: OpaquePointer?)

@_silgen_name("afc_file_open")
func afc_file_open(
    _ client: OpaquePointer?,
    _ path: UnsafePointer<CChar>?,
    _ mode: Int32,
    _ out: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer?

@_silgen_name("afc_file_write")
func afc_file_write(
    _ handle: OpaquePointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> OpaquePointer?

@_silgen_name("afc_file_close")
func afc_file_close(_ handle: OpaquePointer?) -> OpaquePointer?
