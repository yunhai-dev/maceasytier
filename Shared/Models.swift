import Foundation

/// 侧边栏选中项：全部网络 / 收藏 / 自定义分组。
enum SidebarItem: Hashable {
    case overview
    case all
    case favorites
    case group(UUID)
}

/// 首页流量趋势采样点。
struct TrafficPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let rxRate: Double
    let txRate: Double
}

/// 网络配置分组（仅用于 UI 归类）。
struct NetworkGroup: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var isManual: Bool
    var isDisabled: Bool

    init(id: UUID = UUID(), name: String, isManual: Bool = false, isDisabled: Bool = false) {
        self.id = id
        self.name = name
        self.isManual = isManual
        self.isDisabled = isDisabled
    }
}

/// 组网方式：公共共享节点 / 手动填写对等节点 / 只监听等待其他节点接入。
enum NetworkingMethod: String, Codable, CaseIterable, Identifiable {
    case publicServer
    case manual
    case standalone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .publicServer: "通过公共节点加入"
        case .manual: "通过对等节点加入"
        case .standalone: "作为服务端监听"
        }
    }

    var detail: String {
        switch self {
        case .publicServer: "客户端模式：通过公共共享节点加入网络。"
        case .manual: "客户端模式：直接连接一个或多个对等节点。"
        case .standalone: "服务端模式：只监听，不会主动加入网络。"
        }
    }
}

/// 子网代理：把本机可达的网段共享给虚拟网络。
struct ProxyNetwork: Identifiable, Hashable, Codable {
    var id: UUID
    var cidr: String
    var mappedCIDR: String
    var allow: [String]

    init(id: UUID = UUID(), cidr: String = "", mappedCIDR: String = "", allow: [String] = []) {
        self.id = id
        self.cidr = cidr
        self.mappedCIDR = mappedCIDR
        self.allow = allow
    }
}

/// 端口转发：本机 bind -> 虚拟网 dst。
struct PortForwardRule: Identifiable, Hashable, Codable {
    var id: UUID
    var proto: String
    var bindAddress: String
    var destination: String

    init(id: UUID = UUID(), proto: String = "tcp", bindAddress: String = "127.0.0.1:5202", destination: String = "10.144.0.20:5201") {
        self.id = id
        self.proto = proto
        self.bindAddress = bindAddress
        self.destination = destination
    }
}

/// 高级选项：对应 EasyTier `[flags]` 的常用子集。
struct AdvancedConfig: Codable, Hashable {
    var latencyFirst: Bool
    var disableP2P: Bool
    var enableKCPProxy: Bool
    var enableQUICProxy: Bool
    var compression: String
    var encryptionAlgorithm: String
    var mtu: Int
    var relayNetworkWhitelist: String
    var privateMode: Bool
    var acceptDNS: Bool

    init(
        latencyFirst: Bool = false,
        disableP2P: Bool = false,
        enableKCPProxy: Bool = false,
        enableQUICProxy: Bool = false,
        compression: String = "none",
        encryptionAlgorithm: String = "aes-gcm",
        mtu: Int = 0,
        relayNetworkWhitelist: String = "*",
        privateMode: Bool = false,
        acceptDNS: Bool = false
    ) {
        self.latencyFirst = latencyFirst
        self.disableP2P = disableP2P
        self.enableKCPProxy = enableKCPProxy
        self.enableQUICProxy = enableQUICProxy
        self.compression = compression
        self.encryptionAlgorithm = encryptionAlgorithm
        self.mtu = mtu
        self.relayNetworkWhitelist = relayNetworkWhitelist
        self.privateMode = privateMode
        self.acceptDNS = acceptDNS
    }
}

/// 一个 EasyTier 网络配置。网络密钥不落盘，单独存 Keychain。
struct NetworkConfig: Codable, Hashable {
    var instanceName: String
    var networkName: String
    var hostname: String
    var method: NetworkingMethod
    var publicServer: String
    var peers: [String]
    var listeners: [String]
    var noListener: Bool
    var tunEnabled: Bool?
    var dhcp: Bool
    var virtualIPv4: String
    var proxyNetworks: [ProxyNetwork]
    var manualRoutes: [String]
    var exitNodes: [String]
    var enableExitNode: Bool
    var socks5Port: Int?
    var portForwards: [PortForwardRule]
    var advanced: AdvancedConfig

    init(
        instanceName: String = NetworkConfig.defaultInstanceName(),
        networkName: String = "",
        hostname: String = NetworkConfig.defaultHostname(),
        method: NetworkingMethod = .publicServer,
        publicServer: String = NetworkConfig.defaultPublicServer,
        peers: [String] = [],
        listeners: [String] = NetworkConfig.defaultListeners,
        noListener: Bool = false,
        tunEnabled: Bool? = false,
        dhcp: Bool = true,
        virtualIPv4: String = "",
        proxyNetworks: [ProxyNetwork] = [],
        manualRoutes: [String] = [],
        exitNodes: [String] = [],
        enableExitNode: Bool = false,
        socks5Port: Int? = nil,
        portForwards: [PortForwardRule] = [],
        advanced: AdvancedConfig = AdvancedConfig()
    ) {
        self.instanceName = instanceName
        self.networkName = networkName
        self.hostname = hostname
        self.method = method
        self.publicServer = publicServer
        self.peers = peers
        self.listeners = listeners
        self.noListener = noListener
        self.tunEnabled = tunEnabled
        self.dhcp = dhcp
        self.virtualIPv4 = virtualIPv4
        self.proxyNetworks = proxyNetworks
        self.manualRoutes = manualRoutes
        self.exitNodes = exitNodes
        self.enableExitNode = enableExitNode
        self.socks5Port = socks5Port
        self.portForwards = portForwards
        self.advanced = advanced
    }

    static let defaultPublicServer = "tcp://public.easytier.top:11010"
    static let defaultListeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]

    var usesTUN: Bool {
        get { tunEnabled ?? false }
        set { tunEnabled = newValue }
    }

    static func defaultHostname() -> String {
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
    }

    static func defaultInstanceName() -> String {
        let base = defaultHostname()
        return base.isEmpty ? "mac" : base
    }
}

/// 持久化的网络配置（不含密钥）。
struct NetworkProfile: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var groupID: UUID?
    var isFavorite: Bool
    var isDisabled: Bool
    var autoConnect: Bool
    var config: NetworkConfig
    /// 上次成功获得的虚拟 IP（CIDR）。DHCP 网络下次启动时直接沿用，省去 DHCP 等待并保持地址稳定。
    var leasedIPv4: String?

    init(
        id: UUID = UUID(),
        name: String = "新网络",
        groupID: UUID? = nil,
        isFavorite: Bool = false,
        isDisabled: Bool = false,
        autoConnect: Bool = false,
        config: NetworkConfig = NetworkConfig(),
        leasedIPv4: String? = nil
    ) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.isFavorite = isFavorite
        self.isDisabled = isDisabled
        self.autoConnect = autoConnect
        self.config = config
        self.leasedIPv4 = leasedIPv4
    }
}

enum CoreStatus: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed

    var title: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running: "运行中"
        case .stopping: "停止中"
        case .failed: "失败"
        }
    }
}

/// 虚拟 IP 获取阶段：驱动界面上的“获取中…”与自动恢复。
enum IPPhase: Sendable, Equatable {
    case none
    case acquiring
    case assigned
    case failed
}

struct CoreState: Sendable {
    var status: CoreStatus = .stopped
    var error: String?
    var rpcPort: Int?
}

/// 本节点信息（来自 `easytier-cli -o json node`）。
struct NodeInfo: Sendable {
    var virtualIPv4: String
    var hostname: String
    var instanceID: String
    var peerID: UInt32
    var listeners: [String]
    var publicIP: String?
    var natType: String
    var version: String
    var proxyCIDRs: [String]

    var displayVirtualIP: String {
        virtualIPv4.split(separator: "/").first.map(String.init) ?? virtualIPv4
    }
}

/// 对等节点行（已聚合多连接，排除本节点）。
struct PeerRow: Identifiable, Sendable {
    var id: UInt32
    var hostname: String
    var virtualIPv4: String
    var latencyMs: Double?
    var lossRate: Double
    var rxBytes: UInt64
    var txBytes: UInt64
    var tunnelProtocols: String
    var natType: String
    var path: String
    var version: String
    var hasTrafficStats = false
    var rxRate: Double?
    var txRate: Double?

    func sampled(previous: PeerRow?, interval: TimeInterval) -> PeerRow {
        var result = self
        result.rxRate = nil
        result.txRate = nil
        guard hasTrafficStats, let previous, previous.hasTrafficStats, interval > 0 else { return result }
        if rxBytes >= previous.rxBytes { result.rxRate = Double(rxBytes - previous.rxBytes) / interval }
        if txBytes >= previous.txBytes { result.txRate = Double(txBytes - previous.txBytes) / interval }
        return result
    }
}

/// 路由表行。
struct RouteRow: Identifiable, Sendable {
    var id: String
    var peerID: UInt32
    var hostname: String
    var virtualIPv4: String
    var proxyCIDRs: String
    var nextHop: String
    var nextHopHostname: String
    var cost: Int
    var pathLatencyMs: Double
    var isLocal: Bool
    var prefixLength: Int = 24
}

struct TrafficStats: Sendable {
    var rxBytes: UInt64 = 0
    var txBytes: UInt64 = 0
    var rxRate: Double = 0
    var txRate: Double = 0

    var displayText: String {
        "↓ \(Self.rate(rxRate))  ↑ \(Self.rate(txRate))"
    }

    var totalText: String {
        "↓ \(Self.bytes(rxBytes))  ↑ \(Self.bytes(txBytes))"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    static func bytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
