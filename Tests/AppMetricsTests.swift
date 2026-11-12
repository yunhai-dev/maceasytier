import XCTest
@testable import MacEasyTier

@MainActor
final class AppMetricsTests: XCTestCase {
    func testPeerRatesUseCounterDeltasAndRejectMissingOrResetSamples() {
        let initial = PeerRow(id: 7, hostname: "peer", virtualIPv4: "", latencyMs: nil, lossRate: 0,
                              rxBytes: 100, txBytes: 200, tunnelProtocols: "tcp", natType: "",
                              path: "直连", version: "", hasTrafficStats: true)
        var current = initial
        current.rxBytes = 300
        current.txBytes = 500
        let sampled = current.sampled(previous: initial, interval: 2)
        XCTAssertEqual(sampled.rxRate, 100)
        XCTAssertEqual(sampled.txRate, 150)
        XCTAssertNil(current.sampled(previous: nil, interval: 2).rxRate)
        XCTAssertNil(current.sampled(previous: initial, interval: 0).txRate)
        current.rxBytes = 1
        XCTAssertNil(current.sampled(previous: initial, interval: 2).rxRate)
        current.hasTrafficStats = false
        XCTAssertNil(current.sampled(previous: initial, interval: 2).txRate)
    }

    func testTrafficSamplingAndDistribution() async {
        let model = AppModel()
        let id = UUID()

        model.core.traffic[id] = TrafficStats(rxBytes: 1_000, txBytes: 2_000, rxRate: 500, txRate: 600)
        model.core.peers[id] = [
            PeerRow(
                id: 1,
                hostname: "direct",
                virtualIPv4: "10.0.0.1",
                latencyMs: 1,
                lossRate: 0,
                rxBytes: 1_500,
                txBytes: 1_500,
                tunnelProtocols: "tcp",
                natType: "全锥形",
                path: "直连",
                version: "test"
            ),
        ]
        let usageRxBefore = model.usage.totalRx
        let usageTxBefore = model.usage.totalTx
        model.sampleDashboard()

        try? await Task.sleep(for: .milliseconds(120))
        model.core.traffic[id] = TrafficStats(rxBytes: 2_000, txBytes: 4_000, rxRate: 800, txRate: 900)
        model.sampleDashboard()

        XCTAssertGreaterThan(model.latestRxRate, 0)
        XCTAssertGreaterThan(model.latestTxRate, 0)
        XCTAssertGreaterThanOrEqual(model.usage.totalRx, usageRxBefore + 1_000)
        XCTAssertGreaterThanOrEqual(model.usage.totalTx, usageTxBefore + 2_000)
        XCTAssertEqual(model.latestRxRate, 800)
        XCTAssertEqual(model.latestTxRate, 900)
    }
}
