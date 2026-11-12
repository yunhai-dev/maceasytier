import XCTest
@testable import MacEasyTier

final class TOMLCodecTests: XCTestCase {
    func testRenderParseRoundTrip() throws {
        var advanced = AdvancedConfig()
        advanced.latencyFirst = true
        advanced.enableKCPProxy = true
        advanced.compression = "zstd"
        advanced.mtu = 1400
        advanced.privateMode = true

        let config = NetworkConfig(
            instanceName: "inst",
            networkName: "net name",
            hostname: "host",
            method: .manual,
            peers: ["tcp://1.2.3.4:11010", "udp://[::1]:11010"],
            listeners: ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"],
            dhcp: false,
            virtualIPv4: "10.144.144.2/24",
            proxyNetworks: [ProxyNetwork(cidr: "10.1.1.0/24", mappedCIDR: "10.2.2.0/24", allow: ["10.1.1.5"])],
            manualRoutes: ["10.3.3.0/24"],
            exitNodes: ["10.144.144.1"],
            enableExitNode: true,
            socks5Port: 1080,
            portForwards: [PortForwardRule(proto: "tcp", bindAddress: "127.0.0.1:5202", destination: "10.144.0.20:5201")],
            advanced: advanced
        )
        let profile = NetworkProfile(name: "Test", config: config)
        let secret = "p@ss#word\"x"

        let toml = TOMLCodec.render(profile, secret: secret)
        let imported = try TOMLCodec.parse(toml)
        let rendered = TOMLCodec.render(NetworkProfile(name: imported.name, config: imported.config), secret: imported.secret)

        XCTAssertEqual(imported.secret, secret)
        XCTAssertEqual(imported.config.networkName, "net name")
        XCTAssertEqual(imported.config.peers, config.peers)
        XCTAssertEqual(imported.config.listeners, config.listeners)
        XCTAssertEqual(imported.config.virtualIPv4, "10.144.144.2/24")
        XCTAssertEqual(imported.config.proxyNetworks.first?.mappedCIDR, "10.2.2.0/24")
        XCTAssertEqual(imported.config.socks5Port, 1080)
        XCTAssertEqual(imported.config.portForwards.first?.destination, "10.144.0.20:5201")
        XCTAssertEqual(imported.config.advanced.compression, "zstd")
        XCTAssertEqual(toml, rendered)
    }

    func testEmptyListenerArrayIsPreserved() throws {
        let config = NetworkConfig(
            networkName: "n",
            method: .manual,
            peers: ["tcp://1.2.3.4:11010"],
            listeners: [],
            noListener: true
        )
        let profile = NetworkProfile(config: config)
        let imported = try TOMLCodec.parse(TOMLCodec.render(profile, secret: "s"))
        XCTAssertTrue(imported.config.noListener)
        XCTAssertTrue(imported.config.listeners.isEmpty)
    }

    func testValidationCatchesBadInput() {
        let config = NetworkConfig(
            networkName: "",
            method: .publicServer,
            publicServer: "",
            listeners: ["bogus"],
            dhcp: false,
            virtualIPv4: "999.1.1.1",
            proxyNetworks: [ProxyNetwork(cidr: "not-a-cidr")],
            exitNodes: ["nope"]
        )
        let errors = TOMLCodec.validate(config)
        XCTAssertTrue(errors.contains { $0.contains("网络名称") })
        XCTAssertTrue(errors.contains { $0.contains("公共节点") })
        XCTAssertTrue(errors.contains { $0.contains("虚拟 IPv4") })
        XCTAssertTrue(errors.contains { $0.contains("监听地址") })
        XCTAssertTrue(errors.contains { $0.contains("代理网段") })
        XCTAssertTrue(errors.contains { $0.contains("出口节点") })
    }

    func testTunFlagRoundTrip() throws {
        var config = NetworkConfig(networkName: "n", method: .standalone)
        config.usesTUN = true
        let profile = NetworkProfile(config: config)
        let toml = TOMLCodec.render(profile, secret: "s")
        XCTAssertTrue(toml.contains("no_tun = false"))
        let imported = try TOMLCodec.parse(toml)
        XCTAssertTrue(imported.config.usesTUN)

        config.usesTUN = false
        let noTun = TOMLCodec.render(NetworkProfile(config: config), secret: "s")
        XCTAssertTrue(noTun.contains("no_tun = true"))
        XCTAssertFalse(try TOMLCodec.parse(noTun).config.usesTUN)
    }

    func testNonLocalListenerIsRejected() {
        let publicListener = NetworkConfig(
            networkName: "n",
            method: .standalone,
            listeners: ["tcp://8.153.17.121:11010"]
        )
        XCTAssertTrue(TOMLCodec.validate(publicListener).contains { $0.contains("不属于本机") })

        let localListener = NetworkConfig(
            networkName: "n",
            method: .standalone,
            listeners: ["tcp://0.0.0.0:11010", "tcp://127.0.0.1:11011"]
        )
        XCTAssertTrue(TOMLCodec.validate(localListener).isEmpty, "\(TOMLCodec.validate(localListener))")
    }

    func testDefaultProfileIsClientMode() {
        var config = NetworkProfile().config
        XCTAssertEqual(config.method, .publicServer)
        XCTAssertEqual(config.publicServer, NetworkConfig.defaultPublicServer)

        config.networkName = "n"
        XCTAssertTrue(TOMLCodec.validate(config).isEmpty, "\(TOMLCodec.validate(config))")

        var manual = config
        manual.method = .manual
        XCTAssertTrue(TOMLCodec.validate(manual).contains { $0.contains("对等节点地址") })
    }


    func testParseRealisticConfig() throws {
        let text = """
        instance_name = "node-a"
        hostname = "node-a"
        dhcp = true
        listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]

        [network_identity]
        network_name = "demo"
        network_secret = "secret"

        [[peer]]
        uri = "tcp://relay.example.com:11010"

        [[port_forward]]
        proto = "udp"
        bind_addr = "127.0.0.1:5202"
        dst_addr = "10.144.0.20:5201"

        [flags]
        no_tun = true
        latency_first = true
        data_compress_algo = 2
        """
        let imported = try TOMLCodec.parse(text)
        XCTAssertEqual(imported.config.instanceName, "node-a")
        XCTAssertEqual(imported.config.networkName, "demo")
        XCTAssertEqual(imported.config.peers, ["tcp://relay.example.com:11010"])
        XCTAssertEqual(imported.config.portForwards.first?.proto, "udp")
        XCTAssertTrue(imported.config.advanced.latencyFirst)
        XCTAssertEqual(imported.config.advanced.compression, "zstd")
    }
}
