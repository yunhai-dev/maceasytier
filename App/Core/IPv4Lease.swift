import Foundation

/// 虚拟 IPv4 的纯函数工具：租约校验、冲突检测、应用侧选址。
///
/// 背景：core 内置 DHCP 要等到“连上节点 + 随机退避”之后才分配地址，TUN 模式下还要在那之后才建网卡，
/// 一旦其中任何一步卡住，界面上就一直是“未分配”。应用侧记住上次拿到的地址，下次启动直接写成固定 IP，
/// 网卡在 core 启动时同步创建，地址立刻可用且重启不漂移；冲突/失效时再回退到 DHCP。
enum IPv4Lease {
    struct Inet: Equatable {
        var address: UInt32
        var prefix: Int

        var network: UInt32 { prefix == 0 ? 0 : address & (UInt32.max << UInt32(32 - prefix)) }
        var broadcast: UInt32 { network | (prefix == 32 ? 0 : UInt32.max >> UInt32(prefix)) }
        var text: String { Self.format(address) + "/\(prefix)" }

        static func format(_ value: UInt32) -> String {
            "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
        }
    }

    static func parseAddress(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    /// 解析 `a.b.c.d/p`。
    static func parse(_ cidr: String) -> Inet? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let address = parseAddress(String(parts[0])),
              let prefix = Int(parts[1]), (1 ... 30).contains(prefix) else { return nil }
        return Inet(address: address, prefix: prefix)
    }

    /// 租约是否仍可用：自己的地址不能被其他节点占用，且至少与一个已知节点同网段（网络重新规划后租约作废）。
    /// `ownHostname`：重启后其他节点上可能短暂残留“旧的自己”，同主机名的路由不算冲突。
    static func isLeaseUsable(_ lease: String, routes: [RouteRow], ownHostname: String = "") -> Bool {
        guard let own = parse(lease) else { return false }
        var sawPeer = false
        var sameNetwork = false
        for route in routes where !route.isLocal {
            guard let address = parseAddress(route.virtualIPv4) else { continue }
            if !ownHostname.isEmpty, route.hostname == ownHostname {
                continue
            }
            if address == own.address { return false }
            sawPeer = true
            if Inet(address: address, prefix: route.prefixLength).network == own.network {
                sameNetwork = true
            }
        }
        return !sawPeer || sameNetwork
    }

    /// 应用侧选址：在已知节点所在网段里挑最小的空闲主机地址。没有任何节点信息时返回 nil。
    static func pickFree(routes: [RouteRow]) -> String? {
        var used = Set<UInt32>()
        var subnet: Inet?
        for route in routes {
            guard let address = parseAddress(route.virtualIPv4) else { continue }
            used.insert(address)
            if !route.isLocal, subnet == nil {
                subnet = Inet(address: address, prefix: max(8, min(route.prefixLength, 30)))
            }
        }
        guard let subnet else { return nil }
        var candidate = subnet.network + 1
        while candidate < subnet.broadcast {
            if !used.contains(candidate) {
                return Inet(address: candidate, prefix: subnet.prefix).text
            }
            candidate += 1
        }
        return nil
    }
}
