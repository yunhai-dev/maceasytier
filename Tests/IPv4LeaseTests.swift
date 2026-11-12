import XCTest
@testable import MacEasyTier

final class IPv4LeaseTests: XCTestCase {
    private func route(_ ip: String, host: String = "peer", prefix: Int = 24, local: Bool = false) -> RouteRow {
        RouteRow(
            id: "\(host)|\(ip)",
            peerID: 0,
            hostname: host,
            virtualIPv4: ip,
            proxyCIDRs: "",
            nextHop: "DIRECT",
            nextHopHostname: "直连",
            cost: 1,
            pathLatencyMs: 0,
            isLocal: local,
            prefixLength: prefix
        )
    }

    func testParseCIDR() {
        XCTAssertEqual(IPv4Lease.parse("10.144.144.4/24")?.text, "10.144.144.4/24")
        XCTAssertEqual(IPv4Lease.parse("10.144.144.4/24")?.network, IPv4Lease.parseAddress("10.144.144.0"))
        XCTAssertNil(IPv4Lease.parse("10.144.144.4"))
        XCTAssertNil(IPv4Lease.parse("10.144.144.300/24"))
        XCTAssertNil(IPv4Lease.parse("10.144.144.4/0"))
    }

    func testPickFreeSkipsUsedAndNetworkAddress() {
        let routes = [
            route("10.144.144.4", host: "me", local: true),
            route("10.144.144.1"),
            route("10.144.144.2"),
            route("10.144.144.3"),
        ]
        XCTAssertEqual(IPv4Lease.pickFree(routes: routes), "10.144.144.5/24")

        let sparse = [route("10.144.144.2"), route("10.144.144.3")]
        XCTAssertEqual(IPv4Lease.pickFree(routes: sparse), "10.144.144.1/24")
    }

    func testPickFreeNeedsPeers() {
        XCTAssertNil(IPv4Lease.pickFree(routes: []))
        XCTAssertNil(IPv4Lease.pickFree(routes: [route("10.144.144.4", host: "me", local: true)]))
    }

    func testPickFreeExhaustedSubnet() {
        var routes = [route("10.0.0.1", prefix: 30)]
        routes.append(route("10.0.0.2", host: "b", prefix: 30))
        XCTAssertNil(IPv4Lease.pickFree(routes: routes))
    }

    func testLeaseConflictAndNetworkChange() {
        let peers = [route("10.144.144.1"), route("10.144.144.2")]
        XCTAssertTrue(IPv4Lease.isLeaseUsable("10.144.144.4/24", routes: peers))
        XCTAssertFalse(IPv4Lease.isLeaseUsable("10.144.144.2/24", routes: peers))
        // 网络改成了别的网段：租约作废
        XCTAssertFalse(IPv4Lease.isLeaseUsable("10.144.144.4/24", routes: [route("192.168.77.1")]))
        // 还没有任何节点信息：先认为可用
        XCTAssertTrue(IPv4Lease.isLeaseUsable("10.144.144.4/24", routes: []))
        XCTAssertFalse(IPv4Lease.isLeaseUsable("garbage", routes: peers))
    }

    func testStaleSelfRouteIsNotAConflict() {
        // 重启后其他节点上可能还残留“旧的自己”（同主机名、同 IP、不同 peer id）。
        let stale = [route("10.144.144.4", host: "my-mac"), route("10.144.144.1")]
        XCTAssertTrue(IPv4Lease.isLeaseUsable("10.144.144.4/24", routes: stale, ownHostname: "my-mac"))
        XCTAssertFalse(IPv4Lease.isLeaseUsable("10.144.144.4/24", routes: stale, ownHostname: "other"))
    }

    func testStaticOverrideRender() throws {
        let profile = NetworkProfile(config: NetworkConfig(networkName: "n", dhcp: true))
        let dhcp = TOMLCodec.render(profile, secret: "s")
        XCTAssertTrue(dhcp.contains("dhcp = true"))
        XCTAssertFalse(dhcp.contains("ipv4 ="))

        let fixed = TOMLCodec.render(profile, secret: "s", staticIPv4: "10.144.144.4/24")
        XCTAssertTrue(fixed.contains("dhcp = false"))
        XCTAssertTrue(fixed.contains("ipv4 = \"10.144.144.4/24\""))
        XCTAssertFalse(fixed.contains("dhcp = true"))
    }

    func testLeaseSurvivesEditorSaveButNotNetworkChange() {
        var previous = NetworkProfile(name: "lease-test", config: NetworkConfig(networkName: "net-a"))
        previous.leasedIPv4 = "10.144.144.4/24"

        // 编辑器副本带着空租约保存，不应覆盖运行时维护的租约。
        var draft = previous
        draft.leasedIPv4 = nil
        draft.name = "renamed"
        XCTAssertEqual(NetworkStore.reconciled(draft, previous: previous).leasedIPv4, "10.144.144.4/24")

        // 换了网络名，租约作废。
        draft.config.networkName = "net-b"
        XCTAssertNil(NetworkStore.reconciled(draft, previous: previous).leasedIPv4)
    }
}
