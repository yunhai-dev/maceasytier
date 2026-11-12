import XCTest
@testable import MacEasyTier

final class NetworkTopologyTests: XCTestCase {
    func testRPCNextHopIdentifiesRelayInTopology() {
        var response = ProtoWriter()
        response.fieldMessage(1) { route in
            route.fieldVarint(1, 200)
            route.fieldVarint(3, 200)
            route.fieldVarint(4, 1)
            route.fieldString(6, "ali")
        }
        response.fieldMessage(1) { route in
            route.fieldVarint(1, 300)
            route.fieldVarint(3, 200)
            route.fieldVarint(4, 2)
            route.fieldString(6, "q-X99")
        }
        let routes = EasyTierRPC.parseRouteRows(response.data, localPeerID: 100)
        XCTAssertEqual(routes.first { $0.peerID == 300 }?.nextHopHostname, "ali")
        let topology = NetworkTopology.build(routes: [row(100, hostname: "mac", cost: 0, nextHop: "-", isLocal: true)] + routes, publicRelay: "tcp://example.com:11010")
        XCTAssertTrue(topology.direct.contains { $0.id == 200 && $0.isRelay })
        XCTAssertTrue(topology.edges.contains(.init(from: 200, to: 300, kind: .relay)))
        XCTAssertFalse(topology.direct.contains { $0.route.id == "public-relay" })
    }

    func testDirectNodeLinksToLocal() {
        let topology = NetworkTopology.build(routes: [
            row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
            row(2, hostname: "nas", cost: 1, nextHop: "1"),
        ])

        XCTAssertEqual(topology.local?.id, 1)
        XCTAssertEqual(topology.direct.map(\.id), [2])
        XCTAssertTrue(topology.relayed.isEmpty)
        XCTAssertEqual(Set(topology.edges), [
            NetworkTopology.Edge(from: 1, to: 2, kind: .direct),
        ])
    }

    func testRelayedNodeLinksThroughRelayServer() {
        let topology = NetworkTopology.build(routes: [
            row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
            row(2, hostname: "relay", cost: 1, nextHop: "1"),
            row(3, hostname: "behind-relay", cost: 2, nextHop: "2"),
        ])

        XCTAssertEqual(Set(topology.direct.map(\.id)), [2])
        XCTAssertEqual(topology.direct.first { $0.id == 2 }?.isRelay, true)
        XCTAssertEqual(topology.relayed.map(\.id), [3])
        XCTAssertEqual(Set(topology.edges), [
            NetworkTopology.Edge(from: 1, to: 2, kind: .direct),
            NetworkTopology.Edge(from: 2, to: 3, kind: .relay),
        ])
    }

    func testMissingRelayUsesConfiguredPublicNode() {
        let topology = NetworkTopology.build(
            routes: [
                row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
                row(2, hostname: "behind-public", cost: 2, nextHop: "99"),
            ],
            publicRelay: "tcp://public.easytier.top:11010"
        )

        guard let relay = topology.direct.first else { return XCTFail("缺少公共节点") }
        XCTAssertEqual(relay.route.hostname, "公共节点（推测）")
        XCTAssertEqual(relay.route.virtualIPv4, "public.easytier.top:11010")
        XCTAssertEqual(topology.relayed.map(\.id), [2])
        XCTAssertEqual(Set(topology.edges), [
            NetworkTopology.Edge(from: 1, to: relay.id, kind: .direct),
            NetworkTopology.Edge(from: relay.id, to: 2, kind: .relay),
        ])
    }

    func testDirectNetworkHidesUnusedPublicNode() {
        let topology = NetworkTopology.build(
            routes: [
                row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
                row(2, hostname: "nas", cost: 1, nextHop: "1"),
            ],
            publicRelay: "tcp://public.easytier.top:11010"
        )

        XCTAssertEqual(topology.direct.map(\.id), [2])
        XCTAssertTrue(topology.relayed.isEmpty)
    }

    func testMissingRelayFallsBackToDirectEdge() {
        let topology = NetworkTopology.build(routes: [
            row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
            row(2, hostname: "behind-relay", cost: 2, nextHop: "99"),
        ])

        XCTAssertEqual(topology.direct.map(\.id), [2])
        XCTAssertTrue(topology.relayed.isEmpty)
        XCTAssertEqual(Set(topology.edges), [
            NetworkTopology.Edge(from: 1, to: 2, kind: .direct),
        ])
    }

    func testHostnameNextHopResolvesRelay() {
        let topology = NetworkTopology.build(routes: [
            row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
            row(2, hostname: "relay-host", cost: 1, nextHop: "1"),
            row(3, hostname: "target", cost: 3, nextHop: "relay-host"),
        ])

        XCTAssertEqual(Set(topology.edges), [
            NetworkTopology.Edge(from: 1, to: 2, kind: .direct),
            NetworkTopology.Edge(from: 2, to: 3, kind: .relay),
        ])
    }

    func testSearchKeepsRelayServer() {
        let topology = NetworkTopology.build(
            routes: [
                row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true),
                row(2, hostname: "relay", cost: 1, nextHop: "1"),
                row(3, hostname: "behind-relay", cost: 2, nextHop: "2"),
                row(4, hostname: "unrelated", cost: 1, nextHop: "1"),
            ],
            query: "behind"
        )

        XCTAssertEqual(topology.local?.id, 1)
        XCTAssertEqual(topology.direct.map(\.id), [2])
        XCTAssertEqual(topology.relayed.map(\.id), [3])
    }

    func testSearchMatchesHostnameAndAddress() {
        let topology = NetworkTopology.build(
            routes: [
                row(1, hostname: "mac", cost: 0, nextHop: "-", isLocal: true, ip: "10.0.0.1"),
                row(2, hostname: "nas", cost: 1, nextHop: "1", ip: "10.0.0.2"),
                row(3, hostname: "pi", cost: 1, nextHop: "1", ip: "10.0.0.3"),
            ],
            query: "10.0.0.3"
        )

        XCTAssertEqual(topology.direct.map(\.id), [3])
    }

    private func row(
        _ id: UInt32,
        hostname: String,
        cost: Int,
        nextHop: String,
        isLocal: Bool = false,
        ip: String? = nil
    ) -> RouteRow {
        let address = ip ?? "10.0.0.\(id)"
        return RouteRow(
            id: isLocal ? "local" : "\(id)|\(address)",
            peerID: id,
            hostname: hostname,
            virtualIPv4: address,
            proxyCIDRs: "",
            nextHop: nextHop,
            nextHopHostname: cost <= 1 ? "直连" : "中继",
            cost: cost,
            pathLatencyMs: 0,
            isLocal: isLocal
        )
    }
}
