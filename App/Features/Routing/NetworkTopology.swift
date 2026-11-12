import Foundation

/// 拓扑图数据：本机、直连节点、中继服务器，以及经中继到达的节点。
/// 直连节点直接与本机连边；经中继的节点先连到中继服务器，再由中继服务器连到目标。
struct NetworkTopology {
    struct Node: Identifiable {
        let id: UInt32
        var route: RouteRow
        var isLocal = false
        var isRelay = false
    }

    struct Edge: Hashable {
        enum Kind: Hashable {
            case direct
            case relay
        }

        var from: UInt32
        var to: UInt32
        var kind: Kind
    }

    var local: Node?
    var direct: [Node] = []
    var relayed: [Node] = []
    var edges: [Edge] = []

    var isEmpty: Bool {
        local == nil && direct.isEmpty && relayed.isEmpty
    }

    /// 公共节点可能不在路由表中；其身份根据配置推测。

    /// - Parameters:
    ///   - routes: 路由表原始条目（包含本机行）。
    ///   - query: 搜索关键字；匹配的节点会显示，中继服务器即使不匹配也会保留。
    ///   - publicRelay: 配置里的公共节点地址；下一跳无法解析到路由条目时挂到该节点。
    static func build(
        routes: [RouteRow],
        query: String = "",
        publicRelay: String? = nil
    ) -> NetworkTopology {
        var topology = NetworkTopology()
        let localRow = routes.first(where: \.isLocal)
        if let localRow {
            topology.local = Node(id: localRow.peerID, route: localRow, isLocal: true)
        }

        let usedIDs = Set(routes.map(\.peerID))
        let publicID = sequence(first: UInt32.max, next: { $0 > 0 ? $0 - 1 : nil })
            .first { !usedIDs.contains($0) }
        let publicNode: Node? = publicRelay
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { address in
                guard !address.isEmpty, let publicID else { return nil }
                return Self.publicRelayNode(address, id: publicID)
            }

        let byID = Dictionary(routes.map { ($0.peerID, $0) }, uniquingKeysWith: { first, _ in first })
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)

        func matches(_ row: RouteRow) -> Bool {
            guard !keyword.isEmpty else { return true }
            return row.hostname.localizedCaseInsensitiveContains(keyword)
                || row.virtualIPv4.localizedCaseInsensitiveContains(keyword)
                || row.proxyCIDRs.localizedCaseInsensitiveContains(keyword)
        }

        var directIDs: Set<UInt32> = []
        var relayIDs: Set<UInt32> = []
        var relayByTarget: [UInt32: UInt32] = [:]

        for row in routes where !row.isLocal && matches(row) {
            if row.cost <= 1 {
                directIDs.insert(row.peerID)
            } else if let relayID = relayID(for: row, routes: byID, localID: localRow?.peerID) {
                relayByTarget[row.peerID] = relayID
                relayIDs.insert(relayID)
                directIDs.insert(relayID)
            } else if let publicNode {
                relayByTarget[row.peerID] = publicNode.id
                relayIDs.insert(publicNode.id)
                directIDs.insert(publicNode.id)
            } else {
                // 拿不到下一跳时退化成直连展示，至少节点不会丢。
                directIDs.insert(row.peerID)
            }
        }

        topology.direct = routes
            .filter { directIDs.contains($0.peerID) }
            .map { Node(id: $0.peerID, route: $0, isRelay: relayIDs.contains($0.peerID)) }
        if let publicNode, directIDs.contains(publicNode.id) {
            topology.direct.append(publicNode)
        }
        topology.relayed = routes
            .filter { relayByTarget[$0.peerID] != nil }
            .map { Node(id: $0.peerID, route: $0) }

        guard let localID = localRow?.peerID else { return topology }

        var linked: Set<String> = []
        for node in topology.direct where node.id != localID {
            topology.edges.append(Edge(from: localID, to: node.id, kind: .direct))
            linked.insert("\(localID)->\(node.id)")
        }
        for node in topology.relayed {
            guard let relayID = relayByTarget[node.id] else { continue }
            if linked.insert("\(localID)->\(relayID)").inserted {
                topology.edges.append(Edge(from: localID, to: relayID, kind: .direct))
            }
            topology.edges.append(Edge(from: relayID, to: node.id, kind: .relay))
        }
        return topology
    }

    private static func publicRelayNode(_ address: String, id: UInt32) -> Node {
        let host = address.components(separatedBy: "://").last ?? address
        let row = RouteRow(
            id: "public-relay",
            peerID: id,
            hostname: "公共节点（推测）",
            virtualIPv4: host,
            proxyCIDRs: "",
            nextHop: "-",
            nextHopHostname: "公共节点",
            cost: 1,
            pathLatencyMs: 0,
            isLocal: false
        )
        return Node(id: id, route: row, isRelay: true)
    }

    private static func relayID(for row: RouteRow, routes: [UInt32: RouteRow], localID: UInt32?) -> UInt32? {
        let hop = row.nextHop.trimmingCharacters(in: .whitespaces)
        if let id = UInt32(hop), id != row.peerID, id != localID, routes[id] != nil {
            return id
        }
        if !hop.isEmpty, hop != "DIRECT",
           let match = routes.values.first(where: { !$0.isLocal && $0.peerID != row.peerID && $0.hostname == hop }) {
            return match.peerID
        }
        return nil
    }
}
