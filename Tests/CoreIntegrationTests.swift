import XCTest
@testable import MacEasyTier

/// 端到端集成测试：真实安装系统服务、启动 TUN core、验证 IP 与启停耗时。
/// 默认跳过。运行方式（会弹一次管理员密码框；结束时会再弹一次以卸载系统服务）：
///
///   TEST_RUNNER_MACEASYTIER_E2E_CONFIG=/path/to/easytier-config.toml \
///   xcodebuild -project maceasytier.xcodeproj -scheme maceasytier -destination 'platform=macOS' \
///     test -only-testing:MacEasyTierTests/CoreIntegrationTests
@MainActor
final class CoreIntegrationTests: XCTestCase {
    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func waitForIP(_ core: CoreSupervisor, id: UUID, timeout: Double) async -> Double? {
        let t0 = ContinuousClock.now
        while seconds(since: t0) < timeout {
            if let ip = core.nodeInfo[id]?.virtualIPv4, !ip.isEmpty { return seconds(since: t0) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func testTunLifecycleIPAndTiming() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACEASYTIER_E2E_CONFIG"], !path.isEmpty else {
            throw XCTSkip("设置 TEST_RUNNER_MACEASYTIER_E2E_CONFIG 以运行端到端测试")
        }
        let imported = try TOMLCodec.parse(String(contentsOfFile: path, encoding: .utf8))
        var config = imported.config
        config.usesTUN = true
        config.dhcp = true
        config.virtualIPv4 = ""
        config.noListener = true
        config.hostname = "e2e-mac"
        config.instanceName = "e2e-mac"
        var profile = NetworkProfile(name: "e2e", config: config)

        let core = CoreSupervisor()
        var leases: [String?] = []
        core.onLeaseChange = { _, ip in leases.append(ip) }

        var log: [String] = []
        func note(_ text: String) { log.append(text); print("E2E> \(text)") }

        // 1) 安装系统服务（首次会弹授权框）
        let installStart = ContinuousClock.now
        try await core.ensureHelperReady()
        note(String(format: "helper ready after %.2fs (state=%@)", seconds(since: installStart), "\(core.helperState)"))
        XCTAssertEqual(core.helperState, .ready)

        // 2) 首次启动：DHCP
        let id = profile.id
        var t = ContinuousClock.now
        await core.start(profile: profile, secret: imported.secret, logLevel: "info")
        let startElapsed = seconds(since: t)
        note(String(format: "start(DHCP) returned after %.2fs status=%@", startElapsed, "\(core.state(for: id).status)"))
        XCTAssertEqual(core.state(for: id).status, .running, core.state(for: id).error ?? "")

        t = ContinuousClock.now
        let dhcpIPDelay = await waitForIP(core, id: id, timeout: 40)
        note("DHCP ip=\(core.nodeInfo[id]?.virtualIPv4 ?? "nil") +\(dhcpIPDelay.map { String(format: "%.2fs", $0) } ?? "never") after start returned")
        XCTAssertNotNil(dhcpIPDelay, "DHCP 40s 内没有拿到 IP；日志：\n" + (core.logs[id] ?? []).suffix(20).joined(separator: "\n"))

        // 网卡上确实有这个地址
        if let ip = core.nodeInfo[id]?.displayVirtualIP {
            let ifconfig = try runCommand("/sbin/ifconfig", [])
            XCTAssertTrue(ifconfig.contains("inet \(ip) "), "ifconfig 中没有 \(ip)")
        }
        // 租约被记录
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(leases.last ?? nil, core.nodeInfo[id]?.virtualIPv4)
        let lease = leases.last ?? nil

        // 3) 停止耗时
        t = ContinuousClock.now
        await core.stop(id: id)
        let stopElapsed = seconds(since: t)
        note(String(format: "stop returned after %.2fs status=%@", stopElapsed, "\(core.state(for: id).status)"))
        XCTAssertEqual(core.state(for: id).status, .stopped)
        XCTAssertLessThan(stopElapsed, 2.0)

        // 4) 带租约再次启动：固定 IP，IP 应在 start 返回时就已存在
        profile.leasedIPv4 = lease
        t = ContinuousClock.now
        await core.start(profile: profile, secret: imported.secret, logLevel: "info")
        note(String(format: "start(sticky %@) returned after %.2fs status=%@", lease ?? "nil", seconds(since: t), "\(core.state(for: id).status)"))
        XCTAssertEqual(core.state(for: id).status, .running, core.state(for: id).error ?? "")
        let stickyDelay = await waitForIP(core, id: id, timeout: 10)
        note("sticky ip=\(core.nodeInfo[id]?.virtualIPv4 ?? "nil") +\(stickyDelay.map { String(format: "%.2fs", $0) } ?? "never")")
        XCTAssertEqual(core.nodeInfo[id]?.virtualIPv4, lease)
        XCTAssertLessThan(stickyDelay ?? 99, 1.0)

        t = ContinuousClock.now
        await core.stop(id: id)
        note(String(format: "stop returned after %.2fs", seconds(since: t)))
        XCTAssertEqual(core.state(for: id).status, .stopped)

        // 5) 卸载，恢复系统原状
        try await core.uninstallHelper()
        note("helper state after uninstall: \(core.helperState)")
        XCTAssertEqual(core.helperState, .notInstalled)
        core.shutdown()
    }

    private func runCommand(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
