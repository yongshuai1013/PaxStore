//
//  PaxStoreTunnelProvider.swift
//  PaxStoreTunnel
//
//  PaxStore 本地迴環 Packet Tunnel Provider。
//
//  背景：iOS 描述檔（.mobileconfig）不支援 WireGuard（真機報「欄位 VPNType 無效」），
//  因此改用 App 內嵌的 Packet Tunnel Provider 實現本地 VPN（對標 SideStore 的本地迴環 VPN）。
//
//  原理：
//  - Provider 建立 TUN 接口（10.7.0.2/24），把 10.7.0.0/24 的路由指進 tunnel
//  - App 連接 10.7.0.1:<port>（如 lockdownd 的 62078）時，TCP 封包進入 tunnel
//  - Provider 做用戶態 TCP 中繼：解析 TUN 封包，用 NWConnection 連到
//    127.0.0.1 的同端口，雙向轉發數據，回包重新封裝（seq/ack、checksum）寫回 TUN
//  - 不需要 WireGuard 描述檔，不需要第三方 App
//
//  狀態：靜態實現，未真機驗證。TCP 狀態機為簡化版（無重傳、無擁塞控制、
//  無分片重組），真機調試重點：三次握手、seq/ack 同步、checksum、FIN 半關閉。
//
//  注意：此文件獨立於 PaxStoreCore（extension 不鏈接主 framework，避免打包複雜度）。

import Foundation
import Network
import NetworkExtension

// MARK: - 主 Provider

/// 本地迴環 Packet Tunnel Provider
final class PaxStoreTunnelProvider: NEPacketTunnelProvider {

    /// 對端地址：App 側用它訪問手機自身服務（如 10.7.0.1:62078 → lockdownd）
    private let peerAddress = "10.7.0.1"
    /// TUN 接口自身地址
    private let tunnelAddress = "10.7.0.2"
    private let subnetMask = "255.255.255.0"

    fileprivate let syncQueue = DispatchQueue(label: "com.paxside.tunnel.queue")
    private var running = false
    private var connections: [ConnKey: TCPConnection] = [:]

    // MARK: 啟動 / 停止

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peerAddress)

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [subnetMask])
        // 只把 10.7.0.0/24 指進 tunnel，其餘流量走系統默認路由（不影響正常上網）
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.0", subnetMask: subnetMask)]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: 1500)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(error)
                return
            }
            self.syncQueue.async {
                self.running = true
                self.readLoop()
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.running = false
            for conn in self.connections.values {
                conn.invalidate()
            }
            self.connections.removeAll()
            completionHandler()
        }
    }

    // MARK: 讀包循環

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self = self else { return }
            self.syncQueue.async {
                for packet in packets {
                    self.handlePacket(packet)
                }
                if self.running {
                    self.readLoop()
                }
            }
        }
    }

    private func handlePacket(_ packet: Data) {
        guard let (ip, ipPayload) = parseIPv4(packet), ip.proto == 6 /* TCP */ else {
            return // 非 TCP（UDP/ICMP 等）直接丟棄
        }
        guard let tcp = parseTCP(ipPayload) else { return }
        let payload = tcpPayload(ipPayload, header: tcp)
        let key = ConnKey(srcIP: ip.src, srcPort: tcp.srcPort, dstIP: ip.dst, dstPort: tcp.dstPort)

        // 只中繼发往 10.7.0.0/24 的流量
        guard (ip.dst & 0xFFFFFF00) == (0x0A070000 & 0xFFFFFF00) else { return }

        if tcp.flags & TCPFlag.rst != 0 {
            if let conn = connections[key] {
                conn.invalidate()
                connections.removeValue(forKey: key)
            }
            return
        }

        if let conn = connections[key] {
            conn.handleClientPacket(tcp: tcp, payload: payload)
        } else {
            // 新連接：必須是 SYN（不帶 ACK），否則回 RST
            guard tcp.flags & TCPFlag.syn != 0, tcp.flags & TCPFlag.ack == 0 else {
                sendRST(key: key, tcp: tcp, payloadLength: payload.count)
                return
            }
            let conn = TCPConnection(key: key, clientISN: tcp.seq, provider: self)
            connections[key] = conn
            conn.start()
        }
    }

    // MARK: 供 TCPConnection 回調（fileprivate）

    fileprivate func writePacket(_ packet: Data) {
        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: Int32(AF_INET))])
    }

    fileprivate func connectionClosed(_ key: ConnKey) {
        connections.removeValue(forKey: key)
    }

    private func sendRST(key: ConnKey, tcp: TCPHeader, payloadLength: Int) {
        var ackNum = tcp.seq &+ UInt32(payloadLength)
        if tcp.flags & TCPFlag.syn != 0 { ackNum = ackNum &+ 1 }
        if tcp.flags & TCPFlag.fin != 0 { ackNum = ackNum &+ 1 }
        let pkt = buildPacket(
            srcIP: key.dstIP, dstIP: key.srcIP,
            srcPort: key.dstPort, dstPort: key.srcPort,
            seq: 0, ack: ackNum,
            flags: TCPFlag.rst | TCPFlag.ack,
            payload: Data()
        )
        writePacket(pkt)
    }
}

// MARK: - 連接標識

private struct ConnKey: Hashable {
    let srcIP: UInt32
    let srcPort: UInt16
    let dstIP: UInt32
    let dstPort: UInt16
}

// MARK: - TCP 標誌位

private enum TCPFlag {
    static let fin: UInt8 = 0x01
    static let syn: UInt8 = 0x02
    static let rst: UInt8 = 0x04
    static let psh: UInt8 = 0x08
    static let ack: UInt8 = 0x10
}

// MARK: - 單條 TCP 連接（用戶態中繼）

/// 把一條進入 TUN 的 TCP 連接中繼到 127.0.0.1 的同端口。
/// 簡化狀態機：connecting → synSent → established → closing，無重傳。
private final class TCPConnection {

    private enum State {
        case connecting   // NWConnection 建立中
        case synSent      // 已回 SYN+ACK，等客户端第三次握手
        case established  // 雙向轉發中
        case closing      // 半關閉/已關閉
    }

    private let key: ConnKey
    private weak var provider: PaxStoreTunnelProvider?
    private var state: State = .connecting

    /// 客户端 ISN；clientNext = 期望收到的下一個 client seq
    private var clientNext: UInt32
    /// 我們發出的下一個 seq
    private var serverSeq: UInt32 = 0
    private let serverISN: UInt32 = UInt32.random(in: 0...UInt32.max)

    private var nw: NWConnection?

    init(key: ConnKey, clientISN: UInt32, provider: PaxStoreTunnelProvider) {
        self.key = key
        self.provider = provider
        // SYN 本身佔一個序號
        self.clientNext = clientISN &+ 1
    }

    func start() {
        let port = NWEndpoint.Port(integerLiteral: key.dstPort)
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.nw = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, let provider = self.provider else { return }
            switch state {
            case .ready:
                provider.syncQueue.async { self.onUpstreamReady() }
            case .failed, .cancelled:
                provider.syncQueue.async { self.onUpstreamFailed() }
            default:
                break
            }
        }
        conn.start(queue: provider?.syncQueue ?? DispatchQueue.main)
    }

    func invalidate() {
        nw?.cancel()
        nw = nil
    }

    // MARK: 上游（127.0.0.1）事件

    private func onUpstreamReady() {
        guard state == .connecting, let provider = provider else { return }
        state = .synSent
        serverSeq = serverISN
        let pkt = buildPacket(
            srcIP: key.dstIP, dstIP: key.srcIP,
            srcPort: key.dstPort, dstPort: key.srcPort,
            seq: serverSeq, ack: clientNext,
            flags: TCPFlag.syn | TCPFlag.ack,
            payload: Data()
        )
        provider.writePacket(pkt)
        serverSeq = serverSeq &+ 1 // SYN 佔一個序號
        receiveLoop()
    }

    private func onUpstreamFailed() {
        guard let provider = provider else { return }
        // 上游連不上：給客户端回 RST
        let pkt = buildPacket(
            srcIP: key.dstIP, dstIP: key.srcIP,
            srcPort: key.dstPort, dstPort: key.srcPort,
            seq: serverSeq, ack: clientNext,
            flags: TCPFlag.rst | TCPFlag.ack,
            payload: Data()
        )
        provider.writePacket(pkt)
        provider.connectionClosed(key)
    }

    // MARK: 客户端（TUN 側）封包

    func handleClientPacket(tcp: TCPHeader, payload: Data) {
        guard let provider = provider else { return }
        switch state {
        case .connecting:
            // 上游還沒 ready，丟棄（簡化：不緩存早到的包）
            return
        case .synSent:
            // 等待第三次握手
            if tcp.flags & TCPFlag.ack != 0, tcp.ack == serverSeq {
                state = .established
                forwardPayload(tcp: tcp, payload: payload)
            }
        case .established:
            if tcp.flags & TCPFlag.fin != 0 {
                clientNext = tcp.seq &+ UInt32(payload.count) &+ 1
                sendACK(to: provider)
                // 關閉上游，給客户端回 FIN+ACK
                nw?.cancel()
                let pkt = buildPacket(
                    srcIP: key.dstIP, dstIP: key.srcIP,
                    srcPort: key.dstPort, dstPort: key.srcPort,
                    seq: serverSeq, ack: clientNext,
                    flags: TCPFlag.fin | TCPFlag.ack,
                    payload: Data()
                )
                provider.writePacket(pkt)
                serverSeq = serverSeq &+ 1
                state = .closing
                provider.connectionClosed(key)
                return
            }
            forwardPayload(tcp: tcp, payload: payload)
        case .closing:
            return
        }
    }

    private func forwardPayload(tcp: TCPHeader, payload: Data) {
        guard let provider = provider else { return }
        guard !payload.isEmpty else { return } // 純 ACK，忽略
        // 簡化：只接受按序包，亂序則重複 ACK 觸發重傳
        guard tcp.seq == clientNext else {
            sendACK(to: provider)
            return
        }
        clientNext = clientNext &+ UInt32(payload.count)
        nw?.send(content: payload, completion: .contentProcessed({ _ in }))
        sendACK(to: provider)
    }

    private func sendACK(to provider: PaxStoreTunnelProvider) {
        let pkt = buildPacket(
            srcIP: key.dstIP, dstIP: key.srcIP,
            srcPort: key.dstPort, dstPort: key.srcPort,
            seq: serverSeq, ack: clientNext,
            flags: TCPFlag.ack,
            payload: Data()
        )
        provider.writePacket(pkt)
    }

    // MARK: 上游數據 → TUN

    private func receiveLoop() {
        nw?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, let provider = self.provider else { return }
            provider.syncQueue.async {
                if let data = data, !data.isEmpty, self.state != .closing {
                    let pkt = buildPacket(
                        srcIP: self.key.dstIP, dstIP: self.key.srcIP,
                        srcPort: self.key.dstPort, dstPort: self.key.srcPort,
                        seq: self.serverSeq, ack: self.clientNext,
                        flags: TCPFlag.psh | TCPFlag.ack,
                        payload: data
                    )
                    provider.writePacket(pkt)
                    self.serverSeq = self.serverSeq &+ UInt32(data.count)
                }
                if isComplete {
                    // 上游半關閉：給客户端發 FIN
                    if self.state == .established {
                        let pkt = buildPacket(
                            srcIP: self.key.dstIP, dstIP: self.key.srcIP,
                            srcPort: self.key.dstPort, dstPort: self.key.srcPort,
                            seq: self.serverSeq, ack: self.clientNext,
                            flags: TCPFlag.fin | TCPFlag.ack,
                            payload: Data()
                        )
                        provider.writePacket(pkt)
                        self.serverSeq = self.serverSeq &+ 1
                        self.state = .closing
                    }
                    provider.connectionClosed(self.key)
                    return
                }
                if error == nil {
                    self.receiveLoop()
                }
            }
        }
    }
}

// MARK: - IPv4 / TCP 解析與封裝

private struct IPv4Info {
    let src: UInt32
    let dst: UInt32
    let proto: UInt8
}

private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
}

private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
        | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

private func parseIPv4(_ data: Data) -> (info: IPv4Info, payload: Data)? {
    guard data.count >= 20, data[0] >> 4 == 4 else { return nil }
    let headerLength = Int(data[0] & 0x0F) * 4
    guard data.count >= headerLength else { return nil }
    let info = IPv4Info(src: readU32(data, 12), dst: readU32(data, 16), proto: data[9])
    return (info, data[headerLength...])
}

private struct TCPHeader {
    let srcPort: UInt16
    let dstPort: UInt16
    let seq: UInt32
    let ack: UInt32
    let headerLength: Int
    let flags: UInt8
}

private func parseTCP(_ data: Data) -> TCPHeader? {
    guard data.count >= 20 else { return nil }
    let headerLength = Int(data[12] >> 4) * 4
    guard data.count >= headerLength else { return nil }
    return TCPHeader(
        srcPort: readU16(data, 0),
        dstPort: readU16(data, 2),
        seq: readU32(data, 4),
        ack: readU32(data, 8),
        headerLength: headerLength,
        flags: data[13]
    )
}

private func tcpPayload(_ data: Data, header: TCPHeader) -> Data {
    guard data.count > header.headerLength else { return Data() }
    return data[header.headerLength...]
}

/// 一補數 checksum（IP 首部 / TCP 偽首部通用）
private func onesComplementChecksum(_ data: Data) -> UInt16 {
    var sum: UInt32 = 0
    var i = data.startIndex
    while i + 1 < data.endIndex {
        sum = sum &+ (UInt32(data[i]) << 8 | UInt32(data[i + 1]))
        i += 2
    }
    if i < data.endIndex {
        sum = sum &+ (UInt32(data[i]) << 8)
    }
    while sum > 0xFFFF {
        sum = (sum & 0xFFFF) + (sum >> 16)
    }
    return ~UInt16(sum & 0xFFFF)
}

private func appendU16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0xFF))
}

private func appendU32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(value >> 24))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

/// 構造一個 IPv4/TCP 包（回給 TUN 側）
private func buildPacket(
    srcIP: UInt32, dstIP: UInt32,
    srcPort: UInt16, dstPort: UInt16,
    seq: UInt32, ack: UInt32,
    flags: UInt8,
    payload: Data
) -> Data {
    var packet = Data()

    // --- IPv4 首部（20 字節）---
    let totalLength = 20 + 20 + payload.count
    packet.append(0x45) // version=4, IHL=5
    packet.append(0x00) // DSCP/ECN
    appendU16(&packet, UInt16(totalLength))
    let identification = UInt16.random(in: 0...UInt16.max)
    appendU16(&packet, identification)
    packet.append(0x40) // flags: DF
    packet.append(0x00) // fragment offset
    packet.append(64)   // TTL
    packet.append(6)    // protocol: TCP
    appendU16(&packet, 0) // checksum 佔位
    appendU32(&packet, srcIP)
    appendU32(&packet, dstIP)
    let ipSum = onesComplementChecksum(packet)
    packet[10] = UInt8(ipSum >> 8)
    packet[11] = UInt8(ipSum & 0xFF)

    // --- TCP 首部（20 字節，無選項）---
    var tcp = Data()
    appendU16(&tcp, srcPort)
    appendU16(&tcp, dstPort)
    appendU32(&tcp, seq)
    appendU32(&tcp, ack)
    tcp.append(0x50) // data offset=5
    tcp.append(flags)
    appendU16(&tcp, 65535) // window
    appendU16(&tcp, 0)     // checksum 佔位
    appendU16(&tcp, 0)     // urgent pointer

    // TCP checksum（含偽首部）
    var pseudo = Data()
    appendU32(&pseudo, srcIP)
    appendU32(&pseudo, dstIP)
    pseudo.append(0)
    pseudo.append(6) // TCP
    appendU16(&pseudo, UInt16(tcp.count + payload.count))
    pseudo.append(tcp)
    pseudo.append(payload)
    let tcpSum = onesComplementChecksum(pseudo)
    tcp[16] = UInt8(tcpSum >> 8)
    tcp[17] = UInt8(tcpSum & 0xFF)

    packet.append(tcp)
    packet.append(payload)
    return packet
}
