import Darwin
import Foundation

/// 原生 EasyTier 管理 RPC 客户端：直接说 ZCPacket + protobuf 协议，不依赖 easytier-cli。
enum EasyTierRPC {
    struct Snapshot: Sendable {
        var node: NodeInfo
        var peers: [PeerRow]
        var routes: [RouteRow]
        var traffic: TrafficStats
    }

    enum RPCError: LocalizedError {
        case socket(String)
        case protocolError(String)
        case remote(String)

        var errorDescription: String? {
            switch self {
            case let .socket(message): "RPC socket: \(message)"
            case let .protocolError(message): "RPC protocol: \(message)"
            case let .remote(message): message
            }
        }
    }

    /// 与某个 core 的长连接会话：一个 TCP 连接复用所有请求，实例 UUID 只解析一次。
    /// 旧实现每次轮询新建 4 个连接，既慢又让 core 日志被 "rpc server" 噪声刷屏。
    /// 非线程安全：调用方需保证同一时刻只有一个 `fetch` 在执行。
    final class Session: @unchecked Sendable {
        let port: Int
        private var connection: RPCConnection?
        private var instanceUUID: Data?

        init(port: Int) {
            self.port = port
        }

        func fetch() throws -> Snapshot {
            do {
                let connection = try openConnection()
                return try EasyTierRPC.fetch(connection: connection, instanceUUID: &instanceUUID)
            } catch {
                close()
                throw error
            }
        }

        func close() {
            connection?.close()
            connection = nil
            instanceUUID = nil
        }

        private func openConnection() throws -> RPCConnection {
            if let connection { return connection }
            let opened = try RPCConnection(port: port)
            connection = opened
            return opened
        }

        deinit { connection?.close() }
    }

    static func fetch(port: Int) throws -> Snapshot {
        let session = Session(port: port)
        defer { session.close() }
        return try session.fetch()
    }

    private static func fetch(connection: RPCConnection, instanceUUID: inout Data?) throws -> Snapshot {
        if instanceUUID == nil {
            let instanceList = try call(
                connection: connection,
                service: "WebClientService",
                method: 5,
                request: Data()
            )
            guard let uuidBytes = instanceList.protoRepeatedBytes(1).first else {
                throw RPCError.protocolError("no running instance")
            }
            instanceUUID = uuidBytes
        }
        let uuidRequest = instanceRequest(uuid: instanceUUID)

        let nodeData = try call(
            connection: connection,
            service: "PeerManageRpc",
            method: 7,
            request: uuidRequest
        )
        guard let nodeBytes = nodeData.protoBytes(1) else {
            throw RPCError.protocolError("ShowNodeInfoResponse.node_info missing")
        }
        let node = parseNodeInfo(nodeBytes)

        let peerData = try call(
            connection: connection,
            service: "PeerManageRpc",
            method: 1,
            request: uuidRequest
        )
        let routeData = try call(
            connection: connection,
            service: "PeerManageRpc",
            method: 3,
            request: uuidRequest
        )

        var routes = parseRoutes(routeData, localPeerID: node.peerID)
        routes.rows.insert(
            RouteRow(
                id: "local",
                peerID: node.peerID,
                hostname: node.hostname,
                virtualIPv4: node.virtualIPv4,
                proxyCIDRs: node.proxyCIDRs.joined(separator: ", "),
                nextHop: "-",
                nextHopHostname: "本机",
                cost: 0,
                pathLatencyMs: 0,
                isLocal: true
            ),
            at: 0
        )
        let peers = parsePeers(peerData, localPeerID: node.peerID, routes: routes.byPeer)

        var traffic = TrafficStats()
        for peer in peers {
            traffic.rxBytes += peer.rxBytes
            traffic.txBytes += peer.txBytes
        }

        return Snapshot(node: node, peers: peers, routes: routes.rows, traffic: traffic)
    }

    private static func instanceRequest(uuid: Data?) -> Data {
        var identifier = ProtoWriter()
        if let uuid, !uuid.isEmpty {
            identifier.fieldBytes(1, uuid)
        }
        var request = ProtoWriter()
        request.fieldBytes(1, identifier.data)
        return request.data
    }

    // MARK: - RPC

    private static func call(
        connection: RPCConnection,
        service: String,
        method: Int,
        request: Data
    ) throws -> Data {
        let transactionID = UInt64.random(in: 1 ..< (UInt64(1) << 62))

        var descriptor = ProtoWriter()
        descriptor.fieldString(2, service)
        descriptor.fieldString(3, service)
        descriptor.fieldVarint(4, UInt64(method))

        var rpcRequest = ProtoWriter()
        if !request.isEmpty {
            rpcRequest.fieldBytes(2, request)
        }
        rpcRequest.fieldVarint(3, 5_000)

        var compression = ProtoWriter()
        compression.fieldVarint(1, 1) // None
        compression.fieldVarint(2, 1) // accepted None

        var packet = ProtoWriter()
        packet.fieldVarint(1, 1)
        packet.fieldVarint(2, 1)
        packet.fieldVarint(3, transactionID)
        packet.fieldBytes(4, descriptor.data)
        packet.fieldBytes(5, rpcRequest.data)
        packet.fieldVarint(6, 1)
        packet.fieldVarint(7, 1)
        packet.fieldBytes(10, compression.data)

        try connection.sendFrame(payload: packet.data)

        for _ in 0 ..< 6 {
            let payload = try connection.readFrame()
            guard payload.protoVarint(3) == transactionID else { continue }
            guard let responseBytes = payload.protoBytes(5) else {
                throw RPCError.protocolError("RpcResponse missing")
            }
            if let errorBytes = responseBytes.protoBytes(2), errorBytes.protoVarint(1) != 0 {
                throw RPCError.remote(errorBytes.protoString(2) ?? "RPC failed")
            }
            guard let response = responseBytes.protoBytes(1) else {
                // 空响应是合法的：例如网络中没有其他 peer 时 ListPeer 返回空。
                return Data()
            }
            if let compressionInfo = payload.protoBytes(10),
               compressionInfo.protoVarint(1) == 2 {
                throw RPCError.protocolError("server returned zstd-compressed response")
            }
            return response
        }
        throw RPCError.protocolError("no matching RPC response")
    }

    // MARK: - Decode

    private static func parseNodeInfo(_ data: Data) -> NodeInfo {
        let stun = data.protoBytes(5)
        let natValue = Int(stun?.protoVarint(1) ?? 0)
        let publicIP = stun?.protoRepeatedBytes(4).first.map { String(decoding: $0, as: UTF8.self) }

        return NodeInfo(
            virtualIPv4: data.protoString(2) ?? "",
            hostname: data.protoString(4) ?? "",
            instanceID: data.protoString(6) ?? "",
            peerID: UInt32(truncatingIfNeeded: data.protoVarint(1) ?? 0),
            listeners: data.protoRepeatedBytes(7).map { String(decoding: $0, as: UTF8.self) }
                .filter { !$0.hasPrefix("ring://") },
            publicIP: publicIP,
            natType: natName(natValue),
            version: data.protoString(9) ?? "",
            proxyCIDRs: data.protoRepeatedBytes(3).map { String(decoding: $0, as: UTF8.self) }
        )
    }

    private struct RouteInfo {
        var peerID: UInt32
        var hostname: String
        var ipv4: String
        var nextHop: String
        var cost: Int
        var proxyCIDRs: String
        var natType: String
        var version: String
        var pathLatencyMs: Double
        var isLocal: Bool
    }

    private struct RouteCollection {
        var rows: [RouteRow]
        var byPeer: [UInt32: RouteInfo]
    }

    static func parseRouteRows(_ data: Data, localPeerID: UInt32) -> [RouteRow] {
        parseRoutes(data, localPeerID: localPeerID).rows
    }

    private static func parseRoutes(_ data: Data, localPeerID: UInt32) -> RouteCollection {
        var rows: [RouteRow] = []
        var byPeer: [UInt32: RouteInfo] = [:]

        for routeBytes in data.protoRepeatedBytes(1) {
            let peerID = UInt32(truncatingIfNeeded: routeBytes.protoVarint(1) ?? 0)
            let ipv4 = parseIPv4(routeBytes.protoBytes(2)) ?? ""
            let prefixLength = parseIPv4Prefix(routeBytes.protoBytes(2)) ?? 24
            let nextHop = routeBytes.protoVarint(3).map { String(UInt32(truncatingIfNeeded: $0)) } ?? ""
            let cost = Int(routeBytes.protoVarint(4) ?? 0)
            let proxyCIDRs = routeBytes.protoRepeatedBytes(5)
                .map { String(decoding: $0, as: UTF8.self) }
                .joined(separator: ", ")
            let hostname = routeBytes.protoString(6) ?? ""
            let natType = natName(Int(routeBytes.protoBytes(7)?.protoVarint(1) ?? 0))
            let version = routeBytes.protoString(9) ?? ""
            let pathLatency = Double(routeBytes.protoVarint(11) ?? 0) / 1000
            let isLocal = peerID == localPeerID

            let info = RouteInfo(
                peerID: peerID,
                hostname: hostname,
                ipv4: ipv4,
                nextHop: nextHop,
                cost: cost,
                proxyCIDRs: proxyCIDRs,
                natType: natType,
                version: version,
                pathLatencyMs: pathLatency,
                isLocal: isLocal
            )
            byPeer[peerID] = info
            rows.append(
                RouteRow(
                    id: "\(peerID)|\(ipv4)",
                    peerID: peerID,
                    hostname: hostname,
                    virtualIPv4: ipv4,
                    proxyCIDRs: proxyCIDRs,
                    nextHop: nextHop,
                    nextHopHostname: isLocal ? "本机" : (cost <= 1 ? "直连" : "中继"),
                    cost: cost,
                    pathLatencyMs: pathLatency,
                    isLocal: isLocal,
                    prefixLength: prefixLength
                )
            )
        }
        for index in rows.indices where !rows[index].isLocal && rows[index].cost > 1 {
            guard let hopID = UInt32(rows[index].nextHop), let hop = byPeer[hopID] else {
                rows[index].nextHopHostname = rows[index].nextHop.isEmpty ? "未知中继" : "节点 \(rows[index].nextHop)"
                continue
            }
            rows[index].nextHopHostname = hop.hostname.isEmpty ? (hop.ipv4.isEmpty ? "节点 \(hopID)" : hop.ipv4) : hop.hostname
        }
        return RouteCollection(rows: rows, byPeer: byPeer)
    }

    private static func parsePeers(
        _ data: Data,
        localPeerID: UInt32,
        routes: [UInt32: RouteInfo]
    ) -> [PeerRow] {
        var result: [PeerRow] = []

        for peerBytes in data.protoRepeatedBytes(1) {
            let peerID = UInt32(truncatingIfNeeded: peerBytes.protoVarint(1) ?? 0)
            guard peerID != localPeerID else { continue }

            var rx: UInt64 = 0
            var tx: UInt64 = 0
            var hasTrafficStats = false
            var latency: Double?
            var loss: Float = 0
            var protocols = Set<String>()

            for conn in peerBytes.protoRepeatedBytes(2) {
                if let stats = conn.protoBytes(6) {
                    hasTrafficStats = true
                    rx += stats.protoVarint(1) ?? 0
                    tx += stats.protoVarint(2) ?? 0
                    if let microseconds = stats.protoVarint(5) {
                        let milliseconds = Double(microseconds) / 1000
                        latency = min(latency ?? milliseconds, milliseconds)
                    }
                }
                if let value = conn.protoFloat(7) {
                    loss = max(loss, value)
                }
                if let tunnel = conn.protoBytes(5), let type = tunnel.protoString(1), !type.isEmpty {
                    protocols.insert(type)
                }
            }

            let route = routes[peerID]
            result.append(
                PeerRow(
                    id: peerID,
                    hostname: route?.hostname ?? "",
                    virtualIPv4: route?.ipv4 ?? "",
                    latencyMs: latency,
                    lossRate: Double(loss) * 100,
                    rxBytes: rx,
                    txBytes: tx,
                    tunnelProtocols: protocols.sorted().joined(separator: ","),
                    natType: route?.natType ?? "未知",
                    path: (route?.cost ?? 0) <= 1 ? "直连" : "中继",
                    version: route?.version ?? "",
                    hasTrafficStats: hasTrafficStats
                )
            )
        }
        return result
    }

    private static func parseIPv4(_ data: Data?) -> String? {
        guard let data,
              let inet = data.protoBytes(1),
              let raw = inet.protoVarint(1) else { return nil }
        let value = UInt32(truncatingIfNeeded: raw)
        return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private static func parseIPv4Prefix(_ data: Data?) -> Int? {
        guard let data, let length = data.protoVarint(2) else { return nil }
        return Int(length)
    }

    private static func natName(_ value: Int) -> String {
        switch value {
        case 0: "未知"
        case 1: "开放互联网"
        case 2: "无 PAT"
        case 3: "全锥形"
        case 4: "受限锥形"
        case 5: "端口受限"
        case 6: "对称型"
        case 7: "对称型 UDP 防火墙"
        case 8: "对称型（易增量）"
        case 9: "对称型（易减量）"
        default: "未知"
        }
    }

    // MARK: - Socket

    private final class RPCConnection {
        private var descriptor: Int32

        init(port: Int) throws {
            descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                throw RPCError.socket("socket() failed")
            }

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")

            let flags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0, errno != EINPROGRESS {
                throw RPCError.socket("connect failed: \(String(cString: strerror(errno)))")
            }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pollDescriptor, 1, 1_500)
            guard pollResult > 0 else {
                throw RPCError.socket("connect timeout")
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                throw RPCError.socket("connect failed: \(String(cString: strerror(socketError)))")
            }

            _ = fcntl(descriptor, F_SETFL, flags)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        func close() {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
        }

        func sendFrame(payload: Data) throws {
            var frame = Data()
            frame.appendLE32(UInt32(16 + payload.count))
            frame.appendLE32(1)
            frame.appendLE32(1)
            frame.append(8) // RpcReq
            frame.append(0) // flags
            frame.append(0) // forward counter
            frame.append(0) // reserved
            frame.appendLE32(UInt32(payload.count))
            frame.append(payload)
            try write(frame)
        }

        func readFrame() throws -> Data {
            let lengthData = try read(4)
            let length = lengthData.le32
            guard length >= 16, length <= 16 * 1024 * 1024 else {
                throw RPCError.protocolError("invalid frame length \(length)")
            }
            let frame = try read(Int(length))
            let payloadLength = frame[12 ..< 16].le32
            guard payloadLength <= frame.count - 16 else {
                throw RPCError.protocolError("invalid payload length")
            }
            return frame.subdata(in: 16 ..< 16 + Int(payloadLength))
        }

        private func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < data.count {
                    let sent = send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                    if sent < 0 {
                        if errno == EINTR { continue }
                        throw RPCError.socket("send failed: \(String(cString: strerror(errno)))")
                    }
                    offset += sent
                }
            }
        }

        private func read(_ count: Int) throws -> Data {
            var data = Data(count: count)
            let readCount = try data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var offset = 0
                while offset < count {
                    let received = recv(descriptor, base.advanced(by: offset), count - offset, 0)
                    if received == 0 {
                        throw RPCError.socket("connection closed")
                    }
                    if received < 0 {
                        if errno == EINTR { continue }
                        throw RPCError.socket("recv failed: \(String(cString: strerror(errno)))")
                    }
                    offset += received
                }
                return offset
            }
            guard readCount == count else {
                throw RPCError.socket("short read")
            }
            return data
        }
    }
}

private extension Data {
    var le32: UInt32 {
        withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func appendLE32(_ value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
