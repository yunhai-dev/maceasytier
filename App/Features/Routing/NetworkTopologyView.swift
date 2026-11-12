import SwiftUI

/// 网络拓扑：本机在左，直连节点在中，经中继到达的节点在右。
struct NetworkTopologyView: View {
    let topology: NetworkTopology
    let peers: [PeerRow]

    var body: some View {
        if topology.isEmpty {
            ContentUnavailableView(
                "暂无节点",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("发现对等节点后会在这里显示网络拓扑。")
            )
        } else {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    TopologyCanvas(topology: topology, peers: peers)
                        .frame(height: max(proxy.size.height, contentHeight))
                }
            }
        }
    }

    private var contentHeight: CGFloat {
        let rows = max(topology.direct.count, topology.relayed.count)
        return max(320, CGFloat(rows) * (TopologyCanvas.chipHeight + 26) + 28)
    }
}

/// 拓扑画布：节点等距分布，直连为实线、中继为虚线。
struct TopologyCanvas: View {
    static let chipWidth: CGFloat = 184
    static let chipHeight: CGFloat = 70

    let topology: NetworkTopology
    let peers: [PeerRow]

    private let padding: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(
                topology: topology,
                size: proxy.size,
                chipWidth: Self.chipWidth,
                chipHeight: Self.chipHeight,
                padding: padding
            )
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in topology.edges {
                        guard let start = layout.centers[edge.from],
                              let end = layout.centers[edge.to] else { continue }
                        var path = Path()
                        let from = CGPoint(x: start.x + Self.chipWidth / 2, y: start.y)
                        let to = CGPoint(x: end.x - Self.chipWidth / 2 - 3, y: end.y)
                        path.move(to: from)
                        if to.x > from.x {
                            let middle = (from.x + to.x) / 2
                            path.addCurve(
                                to: to,
                                control1: CGPoint(x: middle, y: from.y),
                                control2: CGPoint(x: middle, y: to.y)
                            )
                        } else {
                            path.addLine(to: to)
                        }
                        let color: Color = edge.kind == .relay ? .orange : .green
                        context.stroke(
                            path,
                            with: .color(color.opacity(0.55)),
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                lineCap: .round,
                                dash: edge.kind == .relay ? [5, 4] : []
                            )
                        )
                    }
                }
                ForEach(layout.chips) { chip in
                    nodeView(chip.node)
                        .position(chip.center)
                }
            }
        }
    }

    private var peersByID: [UInt32: PeerRow] {
        Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func nodeView(_ node: NetworkTopology.Node) -> some View {
        let route = node.route
        let peer = node.isLocal || node.route.id == "public-relay" ? nil : peersByID[node.id]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(node))
                    .frame(width: 8, height: 8)
                Text(route.hostname.isEmpty ? "未命名节点" : route.hostname)
                    .font(.callout)
                    .fontWeight(node.isLocal ? .semibold : .regular)
                    .lineLimit(1)
                if node.isRelay {
                    Text("中继")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                Text(subtitle(node, latency: peer?.latencyMs))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let peer {
                    Text(String(format: "丢包 %.1f%%", peer.lossRate))
                        .foregroundStyle(peer.lossRate > 0 ? Color.orange : Color.secondary)
                        .fixedSize()
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            if let peer {
                HStack(spacing: 5) {
                    Text(peer.tunnelProtocols.isEmpty ? "—" : peer.tunnelProtocols.uppercased())
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("↓\(peer.rxRate.map(TrafficStats.rate) ?? "—") ↑\(peer.txRate.map(TrafficStats.rate) ?? "—")")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if !node.isLocal {
                Text("—  ↓— ↑—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: Self.chipWidth, height: Self.chipHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(node.isLocal ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    node.isLocal ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .help(helpText(node))
    }

    private func subtitle(_ node: NetworkTopology.Node, latency: Double?) -> String {
        let raw = node.route.virtualIPv4
        let ip = raw.split(separator: "/").first.map(String.init) ?? "—"
        var parts = [ip]
        if node.isLocal {
            parts.append("本机")
        }
        if let latency {
            parts.append("\(Int(latency.rounded())) ms")
        }
        if node.route.cost > 1 {
            parts.append("中继")
        }
        return parts.joined(separator: " · ")
    }

    private func helpText(_ node: NetworkTopology.Node) -> String {
        let route = node.route
        var lines = [
            route.hostname.isEmpty ? "未命名节点" : route.hostname,
            "虚拟 IP：\(route.virtualIPv4.isEmpty ? "—" : route.virtualIPv4)",
        ]
        if node.isLocal {
            lines.append("本机")
        } else {
            lines.append("路径：\(route.cost <= 1 ? "直连" : "中继")")
            if let latency = peersByID[node.id]?.latencyMs, route.id != "public-relay" {
                lines.append("延迟：\(Int(latency.rounded())) ms")
            }
        }
        if !route.proxyCIDRs.isEmpty {
            lines.append("代理网段：\(route.proxyCIDRs)")
        }
        return lines.joined(separator: "\n")
    }

    private func statusColor(_ node: NetworkTopology.Node) -> Color {
        if node.isLocal {
            return .accentColor
        }
        if node.isRelay || node.route.cost > 1 {
            return .orange
        }
        return .green
    }

    private struct Layout {
        struct Chip: Identifiable {
            let node: NetworkTopology.Node
            let center: CGPoint

            var id: UInt32 { node.id }
        }

        let chips: [Chip]
        let centers: [UInt32: CGPoint]
        let chipWidth: CGFloat

        init(
            topology: NetworkTopology,
            size: CGSize,
            chipWidth: CGFloat,
            chipHeight: CGFloat,
            padding: CGFloat
        ) {
            self.chipWidth = chipWidth

            let minX = padding + chipWidth / 2
            let maxX = max(minX, size.width - padding - chipWidth / 2)
            func column(_ fraction: CGFloat) -> CGFloat {
                min(max(size.width * fraction, minX), maxX)
            }

            let localX: CGFloat
            let middleX: CGFloat
            if topology.direct.isEmpty && topology.relayed.isEmpty {
                localX = (minX + maxX) / 2
                middleX = localX
            } else if topology.relayed.isEmpty {
                localX = column(0.3)
                middleX = column(0.7)
            } else {
                localX = column(0.18)
                middleX = column(0.5)
            }
            let rightX = column(0.82)
            let top = padding + chipHeight / 2
            let bottom = max(top, size.height - padding - chipHeight / 2)
            let centerY = (top + bottom) / 2
            let directY = Self.spread(count: topology.direct.count, top: top, bottom: bottom)

            var chips: [Chip] = []
            var centers: [UInt32: CGPoint] = [:]

            for (index, node) in topology.direct.enumerated() {
                let center = CGPoint(x: middleX, y: directY[index])
                centers[node.id] = center
                chips.append(Chip(node: node, center: center))
            }

            if let local = topology.local {
                let center = CGPoint(x: localX, y: centerY)
                centers[local.id] = center
                chips.append(Chip(node: local, center: center))
            }

            let relayedY = Self.spread(count: topology.relayed.count, top: top, bottom: bottom)
            for (index, node) in topology.relayed.enumerated() {
                let center = CGPoint(x: rightX, y: relayedY[index])
                centers[node.id] = center
                chips.append(Chip(node: node, center: center))
            }

            self.chips = chips
            self.centers = centers
        }

        private static func spread(count: Int, top: CGFloat, bottom: CGFloat) -> [CGFloat] {
            guard count > 0 else { return [] }
            guard count > 1 else { return [(top + bottom) / 2] }
            let step = (bottom - top) / CGFloat(count - 1)
            return (0..<count).map { top + CGFloat($0) * step }
        }
    }
}
