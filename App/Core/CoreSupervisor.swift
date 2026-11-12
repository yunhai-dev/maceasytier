import Darwin
import Foundation
import Observation

/// 管理每个网络配置对应的 easytier-core，并轮询运行状态。
///
/// - 无 TUN：core 作为当前用户的子进程运行。
/// - TUN：通过常驻 root 守护进程（`PrivilegedHelper`）启动，首次需要一次管理员授权，之后启停无需密码。
///
/// 设计要点（相对旧实现）：
/// - 所有阻塞 I/O（RPC、helper socket、哈希）都在后台线程；主 actor 只改状态。
/// - 每个 core 一条长连接 RPC，`--check-config` 子进程不再出现在启动路径上。
/// - 虚拟 IP：沿用上次租约（固定 IP，启动即有）→ 失败回退 DHCP → 卡住自动重启 → 应用侧选址。
@MainActor
@Observable
final class CoreSupervisor {
    struct RunningCore {
        var process: Process?
        var helperPID: Int32?
        let rpcPort: Int
        let instanceName: String
        let logURL: URL
        let logHandle: FileHandle?
        let startedAt: Date
        let session: EasyTierRPC.Session

        var viaHelper: Bool { helperPID != nil }
    }

    enum HelperState: Equatable, Sendable {
        case unknown
        case notInstalled
        case ready
        case outdated
        case unavailable(String)
    }

    /// 启动/恢复时的 IP 策略。
    enum IPMode: Equatable {
        /// 按配置：DHCP 网络优先沿用上次租约。
        case configured
        /// 强制使用 core 内置 DHCP。
        case dhcp
        /// 应用侧选定的固定地址（CIDR）。
        case fixed(String)
    }

    private struct LaunchRecord {
        var profile: NetworkProfile
        var secret: String
        var logLevel: String
    }

    private enum LaunchOutcome {
        case started
        case failed(usedFixedIP: Bool)
    }

    var running: [UUID: RunningCore] = [:]
    var states: [UUID: CoreState] = [:]
    var nodeInfo: [UUID: NodeInfo] = [:]
    var peers: [UUID: [PeerRow]] = [:]
    var routes: [UUID: [RouteRow]] = [:]
    var traffic: [UUID: TrafficStats] = [:]
    var logs: [UUID: [String]] = [:]
    var ipPhase: [UUID: IPPhase] = [:]
    var coreVersion: String?
    var helperState: HelperState = .unknown
    var helperBusy = false

    /// 租约变化回调（nil 表示租约作废）。由 AppModel 接到 NetworkStore 持久化。
    @ObservationIgnored var onLeaseChange: ((UUID, String?) -> Void)?

    @ObservationIgnored private var logOffsets: [UUID: UInt64] = [:]
    @ObservationIgnored private var trafficSamples: [UUID: (date: Date, rx: UInt64, tx: UInt64)] = [:]
    @ObservationIgnored private var startingIDs: Set<UUID> = []
    @ObservationIgnored private var recovering: Set<UUID> = []
    @ObservationIgnored private var launches: [UUID: LaunchRecord] = [:]
    @ObservationIgnored private var fixedIPInUse: Set<UUID> = []
    @ObservationIgnored private var ipSince: [UUID: Date] = [:]
    @ObservationIgnored private var peersSeenAt: [UUID: Date] = [:]
    @ObservationIgnored private var recoveryStep: [UUID: Int] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var didResolveVersions = false
    @ObservationIgnored private var coreMemoryBytes: UInt64 = 0
    @ObservationIgnored private var expectedHelperTag: String?

    /// DHCP 在连上节点后超过该时长仍无 IP，视为卡住并触发恢复。
    private static let ipStallThreshold: TimeInterval = 10
    private static let readyTimeout: TimeInterval = 15

    init() {
        startMonitoring()
    }

    func state(for id: UUID) -> CoreState {
        states[id] ?? CoreState()
    }

    func isRunning(_ id: UUID) -> Bool {
        running[id] != nil
    }

    /// 所有 easytier-core 进程的物理内存占用总和。
    var memoryFootprintBytes: UInt64 { coreMemoryBytes }

    // MARK: - Lifecycle

    func start(profile: NetworkProfile, secret: String, logLevel: String) async {
        let id = profile.id
        guard running[id] == nil, !startingIDs.contains(id), !recovering.contains(id) else { return }
        startingIDs.insert(id)
        defer { startingIDs.remove(id) }

        launches[id] = LaunchRecord(profile: profile, secret: secret, logLevel: logLevel)
        recoveryStep[id] = 0
        await launchWithFallback(id: id, mode: .configured)
    }

    /// 启动；若使用固定 IP（租约）失败，立即以 DHCP 重试一次。
    private func launchWithFallback(id: UUID, mode: IPMode) async {
        let outcome = await launch(id: id, mode: mode)
        if case .failed(usedFixedIP: true) = outcome, launches[id] != nil {
            dropLease(id)
            _ = await launch(id: id, mode: .dhcp)
        }
    }

    private func launch(id: UUID, mode: IPMode) async -> LaunchOutcome {
        guard let record = launches[id] else { return .failed(usedFixedIP: false) }
        let profile = record.profile

        states[id] = CoreState(status: .starting)
        clearRuntimeData(id)
        ipPhase[id] = IPPhase.none
        ipSince[id] = nil
        peersSeenAt[id] = nil

        guard let core = CLIBridge.locateCore() else {
            fail(id, "未找到 easytier-core。请运行 Scripts/fetch-core.sh 或安装 EasyTier。")
            return .failed(usedFixedIP: false)
        }
        // 只做进程内校验；core 自身会在启动时再次解析配置，错误从日志尾部回显。
        let errors = TOMLCodec.validate(profile.config)
        guard errors.isEmpty else {
            fail(id, errors.joined(separator: "\n"))
            return .failed(usedFixedIP: false)
        }

        let fixedIP = fixedIPv4(for: profile, mode: mode)
        let usedFixedIP = fixedIP != nil
        if usedFixedIP { fixedIPInUse.insert(id) } else { fixedIPInUse.remove(id) }

        do {
            try AppPaths.prepareNetworkDirectory(for: id)
            let configURL = AppPaths.configFile(for: id)
            let toml = TOMLCodec.render(profile, secret: record.secret, staticIPv4: fixedIP)
            try Data(toml.utf8).write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

            let logURL = AppPaths.logFile(for: id)
            try? FileManager.default.removeItem(at: logURL)
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let port = PortAllocator.freePort()
            logOffsets[id] = 0
            logs[id] = []
            let session = EasyTierRPC.Session(port: port)

            if profile.config.usesTUN {
                try await ensureHelperReady()
                let ownerPID = ProcessInfo.processInfo.processIdentifier
                let compression = profile.config.advanced.compression
                let level = record.logLevel
                let pid = try await Task.detached(priority: .userInitiated) {
                    try PrivilegedHelper.startCore(
                        id: id,
                        rpcPort: port,
                        ownerPID: ownerPID,
                        logLevel: level,
                        compression: compression,
                        configPath: configURL.path,
                        logPath: logURL.path
                    )
                }.value
                running[id] = RunningCore(
                    process: nil,
                    helperPID: pid,
                    rpcPort: port,
                    instanceName: profile.config.instanceName,
                    logURL: logURL,
                    logHandle: nil,
                    startedAt: Date(),
                    session: session
                )
            } else {
                // O_APPEND：清空日志（截断）后 core 的写入位置不会留下空洞。
                let descriptor = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
                guard descriptor >= 0 else {
                    throw CLIBridge.CommandError(message: "无法打开日志文件：\(String(cString: strerror(errno)))")
                }
                let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                let process = Process()
                process.executableURL = core
                process.standardOutput = logHandle
                process.standardError = logHandle
                process.currentDirectoryURL = AppPaths.networkDirectory(for: id)
                var arguments = [
                    "--disable-env-parsing",
                    "--config-file", configURL.path,
                    "--rpc-portal", "127.0.0.1:\(port)",
                    "--console-log-level", record.logLevel,
                ]
                if profile.config.advanced.compression != "none" {
                    arguments += ["--compression", profile.config.advanced.compression]
                }
                process.arguments = arguments
                process.terminationHandler = { [weak self] _ in
                    Task { @MainActor in self?.refreshNow() }
                }
                try process.run()

                running[id] = RunningCore(
                    process: process,
                    helperPID: nil,
                    rpcPort: port,
                    instanceName: profile.config.instanceName,
                    logURL: logURL,
                    logHandle: logHandle,
                    startedAt: Date(),
                    session: session
                )
            }

            let readiness = await waitUntilReady(id: id)
            if readiness.ready {
                states[id] = CoreState(status: .running, rpcPort: port)
                return .started
            }
            if let core = running[id], isAlive(core) {
                // core 仍在运行但管理 RPC 尚未响应：不要杀进程，交给 monitor 继续尝试。
                let detail = tailLog(id: id)
                let reason = readiness.error ?? "本地 RPC 尚未响应"
                states[id] = CoreState(
                    status: .running,
                    error: detail.isEmpty ? "本地 RPC 尚未就绪：\(reason)" : detail,
                    rpcPort: port
                )
                return .started
            }
            let detail = tailLog(id: id)
            discardFailedLaunch(id)
            fail(id, detail.isEmpty ? "easytier-core 未能就绪。" : detail)
            return .failed(usedFixedIP: usedFixedIP)
        } catch {
            discardFailedLaunch(id)
            fail(id, error.localizedDescription)
            return .failed(usedFixedIP: usedFixedIP)
        }
    }

    /// 用户主动停止。
    func stop(id: UUID) async {
        launches[id] = nil
        recoveryStep[id] = nil
        await teardown(id)
    }

    /// 停止 core 但保留启动记录（供自动恢复重启使用）。
    private func teardown(_ id: UUID) async {
        guard let core = running[id] else {
            states[id] = CoreState(status: .stopped)
            ipPhase[id] = IPPhase.none
            return
        }
        states[id] = CoreState(status: .stopping, rpcPort: core.rpcPort)

        if let process = core.process {
            await terminate(process)
        } else if core.viaHelper {
            // 守护进程在 core 真正退出后才应答，所以这里没有轮询。
            _ = await Task.detached(priority: .userInitiated) { () -> Bool in
                (try? PrivilegedHelper.stopCore(id: id)) != nil
            }.value
            if isAlive(core), let pid = core.helperPID {
                states[id] = CoreState(status: .failed, error: "未能停止 TUN 核心（pid \(pid)），请在设置里重新安装系统服务。")
                return
            }
        }
        finalizeStop(id)
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0 ..< 75 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        kill(process.processIdentifier, SIGKILL)
        for _ in 0 ..< 25 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func remove(id: UUID) async {
        await stop(id: id)
        states[id] = nil
        nodeInfo[id] = nil
        peers[id] = nil
        routes[id] = nil
        traffic[id] = nil
        logs[id] = nil
        ipPhase[id] = nil
        logOffsets[id] = nil
        trafficSamples[id] = nil
    }

    func clearLogs(id: UUID) {
        logs[id] = []
        let url = AppPaths.logFile(for: id)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logOffsets[id] = 0
    }

    /// App 退出时调用（同步）：用户进程直接 terminate；TUN core 让守护进程一并结束。
    /// 守护进程还会在 owner pid 消失时兜底清理，所以崩溃/强杀也不会留下 root core。
    func shutdown() {
        monitorTask?.cancel()
        var hasHelperCores = false
        for core in running.values {
            if let process = core.process {
                process.terminationHandler = nil
                process.terminate()
            } else if core.viaHelper {
                hasHelperCores = true
            }
            core.session.close()
        }
        if hasHelperCores {
            try? PrivilegedHelper.stopAll()
        }
    }

    // MARK: - Privileged helper

    func refreshHelperState() async {
        let expected = await expectedTag()
        let status = await Task.detached(priority: .utility) { try? PrivilegedHelper.status() }.value
        if let status {
            helperState = (status.protocolVersion == PrivilegedHelper.protocolVersion && status.tag == expected)
                ? .ready : .outdated
        } else if FileManager.default.fileExists(atPath: PrivilegedHelper.plistPath) {
            helperState = .unavailable("已安装但未响应")
        } else {
            helperState = .notInstalled
        }
    }

    private func expectedTag() async -> String? {
        if let expectedHelperTag { return expectedHelperTag }
        guard let helper = CLIBridge.locateHelper(), let core = CLIBridge.locateCore() else { return nil }
        let tag = await Task.detached(priority: .utility) {
            PrivilegedHelper.expectedTag(helper: helper, core: core)
        }.value
        expectedHelperTag = tag
        return tag
    }

    /// 确保系统服务可用：缺失或版本过旧时弹一次管理员授权安装/更新。
    func ensureHelperReady() async throws {
        await refreshHelperState()
        if helperState == .ready { return }
        try await installHelper()
    }

    func installHelper() async throws {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }

        guard let helper = CLIBridge.locateHelper(), let core = CLIBridge.locateCore(), let tag = await expectedTag() else {
            throw PrivilegedHelper.HelperError(message: "App 内缺少 MacEasyTierHelper 或 easytier-core。")
        }
        try await PrivilegedHelper.install(helper: helper, core: core, tag: tag)
        for _ in 0 ..< 50 {
            await refreshHelperState()
            if helperState == .ready { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw PrivilegedHelper.HelperError(
            message: "系统服务已安装但未能启动，详见 /var/log/\(PrivilegedHelper.label).log"
        )
    }

    func uninstallHelper() async throws {
        guard !helperBusy else { return }
        helperBusy = true
        defer { helperBusy = false }
        for id in Array(running.keys) where running[id]?.viaHelper == true {
            await stop(id: id)
        }
        try await PrivilegedHelper.uninstall()
        await refreshHelperState()
    }

    // MARK: - Monitoring

    func refreshNow() {
        Task { await tick() }
    }

    private func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.pollInterval()
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self.tick()
            }
        }
    }

    /// 启动中/等待 IP 时快速轮询，稳定后放慢。
    private func pollInterval() -> Duration {
        let busy = running.keys.contains { id in
            states[id]?.status == .starting || ipPhase[id] == .acquiring
        }
        return busy ? .milliseconds(500) : .seconds(2)
    }

    @ObservationIgnored private var isTicking = false

    private func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        if !didResolveVersions {
            didResolveVersions = true
            if let core = CLIBridge.locateCore() {
                coreVersion = await CLIBridge.version(executable: core)
            }
        }

        let ids = Array(running.keys)

        // 1) 存活检查 + 日志
        var fetchTargets: [(UUID, EasyTierRPC.Session)] = []
        for id in ids {
            guard let core = running[id] else { continue }
            readLogs(id: id, logURL: core.logURL)
            let status = states[id]?.status
            if status == .stopping || status == .starting || recovering.contains(id) { continue }

            if !isAlive(core) {
                handleUnexpectedExit(id)
                continue
            }
            fetchTargets.append((id, core.session))
        }

        // 2) 并发拉取各 core 的快照（后台线程，长连接）
        let results = await withTaskGroup(of: (UUID, EasyTierRPC.Snapshot?).self) { group in
            for (id, session) in fetchTargets {
                group.addTask { (id, try? session.fetch()) }
            }
            var collected: [(UUID, EasyTierRPC.Snapshot?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (id, snapshot) in results {
            guard running[id] != nil, let snapshot else { continue }
            apply(snapshot, id: id)
            if var state = states[id], state.status == .running, state.error != nil, ipPhase[id] != .failed {
                state.error = nil
                states[id] = state
            }
        }

        // 3) IP 看门狗
        for id in fetchTargets.map(\.0) {
            evaluateIP(id: id)
        }

        await updateMemoryFootprint()
    }

    private func handleUnexpectedExit(_ id: UUID) {
        let detail = tailLog(id: id)
        let usedFixed = fixedIPInUse.contains(id)
        discardFailedLaunch(id)
        fail(id, detail.isEmpty ? "easytier-core 已退出。" : detail)
        // 固定 IP（租约）导致的退出，自动回到 DHCP 再试一次，用户无感。
        if usedFixed, launches[id] != nil, !recovering.contains(id) {
            dropLease(id)
            scheduleRestart(id: id, mode: .dhcp)
        }
    }

    private func apply(_ snapshot: EasyTierRPC.Snapshot, id: UUID) {
        nodeInfo[id] = snapshot.node
        let now = Date()
        let previous = Dictionary((peers[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let interval = trafficSamples[id].map { now.timeIntervalSince($0.date) } ?? 0
        peers[id] = snapshot.peers.map { $0.sampled(previous: previous[$0.id], interval: interval) }
        routes[id] = snapshot.routes
        traffic[id] = sampleTraffic(id: id, stats: snapshot.traffic, now: now)
        if !snapshot.peers.isEmpty, peersSeenAt[id] == nil {
            peersSeenAt[id] = Date()
        }
    }

    private func sampleTraffic(id: UUID, stats: TrafficStats, now: Date) -> TrafficStats {
        var updated = stats
        if let previous = trafficSamples[id] {
            let interval = max(now.timeIntervalSince(previous.date), 0.1)
            let rxDelta = stats.rxBytes >= previous.rx ? stats.rxBytes - previous.rx : 0
            let txDelta = stats.txBytes >= previous.tx ? stats.txBytes - previous.tx : 0
            updated.rxRate = Double(rxDelta) / interval
            updated.txRate = Double(txDelta) / interval
        }
        trafficSamples[id] = (now, stats.rxBytes, stats.txBytes)
        return updated
    }

    private func waitUntilReady(id: UUID) async -> (ready: Bool, error: String?) {
        var lastError: String?
        let deadline = Date().addingTimeInterval(Self.readyTimeout)
        while Date() < deadline {
            guard let core = running[id] else { return (false, lastError) }
            readLogs(id: id, logURL: core.logURL)
            if !isAlive(core) { return (false, lastError) }
            let session = core.session
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try session.fetch()
                }.value
                apply(snapshot, id: id)
                if snapshot.node.virtualIPv4.isEmpty {
                    ipPhase[id] = .acquiring
                    ipSince[id] = Date()
                } else {
                    ipPhase[id] = .assigned
                    noteAssigned(id: id, ip: snapshot.node.virtualIPv4)
                }
                return (true, nil)
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return (false, lastError)
    }

    private func isAlive(_ core: RunningCore) -> Bool {
        if let process = core.process {
            return process.isRunning
        }
        if let pid = core.helperPID {
            return processAlive(pid)
        }
        return false
    }

    private func finalizeStop(_ id: UUID) {
        if let core = running.removeValue(forKey: id) {
            core.session.close()
            try? core.logHandle?.close()
        }
        clearRuntimeData(id)
        ipPhase[id] = IPPhase.none
        states[id] = CoreState(status: .stopped)
        Task { await updateMemoryFootprint() }
    }

    /// 启动失败/意外退出后的清理：确保进程已结束并释放资源，但不改写状态。
    private func discardFailedLaunch(_ id: UUID) {
        guard let core = running.removeValue(forKey: id) else {
            clearRuntimeData(id)
            return
        }
        core.session.close()
        if let process = core.process {
            if process.isRunning { process.terminate() }
        } else if core.viaHelper {
            Task.detached(priority: .userInitiated) { try? PrivilegedHelper.stopCore(id: id) }
        }
        try? core.logHandle?.close()
        clearRuntimeData(id)
        ipPhase[id] = IPPhase.none
        Task { await updateMemoryFootprint() }
    }

    private func clearRuntimeData(_ id: UUID) {
        nodeInfo[id] = nil
        peers[id] = nil
        routes[id] = nil
        traffic[id] = nil
        trafficSamples[id] = nil
    }

    private func fail(_ id: UUID, _ message: String) {
        states[id] = CoreState(status: .failed, error: message)
    }

    // MARK: - Virtual IP

    private func fixedIPv4(for profile: NetworkProfile, mode: IPMode) -> String? {
        switch mode {
        case .dhcp:
            return nil
        case let .fixed(cidr):
            return cidr
        case .configured:
            guard profile.config.dhcp, let lease = profile.leasedIPv4, IPv4Lease.parse(lease) != nil else { return nil }
            return lease
        }
    }

    private func noteAssigned(id: UUID, ip: String) {
        recoveryStep[id] = 0
        guard var record = launches[id], record.profile.config.dhcp else { return }
        // 应用侧选址后也记作租约，下次启动直接沿用。
        if record.profile.leasedIPv4 != ip {
            record.profile.leasedIPv4 = ip
            launches[id] = record
            onLeaseChange?(id, ip)
        }
    }

    private func dropLease(_ id: UUID) {
        guard var record = launches[id], record.profile.leasedIPv4 != nil else { return }
        record.profile.leasedIPv4 = nil
        launches[id] = record
        onLeaseChange?(id, nil)
    }

    /// 每个轮询周期检查一次：已分配 → 记租约/查冲突；未分配 → 判断是否卡住并分级恢复。
    private func evaluateIP(id: UUID) {
        guard states[id]?.status == .running, !recovering.contains(id), let node = nodeInfo[id] else { return }

        if !node.virtualIPv4.isEmpty {
            ipPhase[id] = .assigned
            noteAssigned(id: id, ip: node.virtualIPv4)

            if fixedIPInUse.contains(id), let rows = routes[id],
               !IPv4Lease.isLeaseUsable(node.virtualIPv4, routes: rows, ownHostname: node.hostname) {
                // 沿用的地址已被别的节点占用，或网络网段已变：作废租约，回到 DHCP。
                dropLease(id)
                scheduleRestart(id: id, mode: .dhcp)
            }
            return
        }

        guard ipPhase[id] == .acquiring else { return }
        // DHCP 要等连上节点才开始，所以从“看到节点”起算。
        guard let seen = peersSeenAt[id] else { return }
        let since = max(seen, ipSince[id] ?? seen)
        guard Date().timeIntervalSince(since) > Self.ipStallThreshold else { return }

        switch recoveryStep[id] ?? 0 {
        case 0:
            recoveryStep[id] = 1
            scheduleRestart(id: id, mode: .dhcp)
        case 1:
            if let rows = routes[id], let ip = IPv4Lease.pickFree(routes: rows) {
                recoveryStep[id] = 2
                scheduleRestart(id: id, mode: .fixed(ip))
            } else {
                markIPFailed(id)
            }
        default:
            markIPFailed(id)
        }
    }

    private func markIPFailed(_ id: UUID) {
        guard ipPhase[id] != .failed else { return }
        ipPhase[id] = .failed
        let detail = tailLog(id: id)
        states[id] = CoreState(
            status: .running,
            error: detail.isEmpty ? "已连上节点，但始终未能获取虚拟 IP。" : "未能获取虚拟 IP：\n" + detail,
            rpcPort: running[id]?.rpcPort
        )
    }

    private func scheduleRestart(id: UUID, mode: IPMode) {
        guard launches[id] != nil, !recovering.contains(id) else { return }
        recovering.insert(id)
        Task { [weak self] in
            guard let self else { return }
            await self.teardown(id)
            if self.launches[id] != nil {
                await self.launchWithFallback(id: id, mode: mode)
            }
            self.recovering.remove(id)
        }
    }

    // MARK: - Memory

    private func updateMemoryFootprint() async {
        var total: UInt64 = 0
        var needsHelper = false
        for core in running.values {
            if core.viaHelper {
                needsHelper = true
            } else if let process = core.process, process.isRunning {
                total += easytier_process_footprint(process.processIdentifier)
            }
        }
        if needsHelper {
            let status = await Task.detached(priority: .utility) { try? PrivilegedHelper.status() }.value
            total += status?.cores.reduce(into: UInt64(0)) { $0 += $1.footprint } ?? 0
        }
        coreMemoryBytes = total
    }

    // MARK: - Orphans

    /// 扫描仍由本 App 的 Helpers 目录启动、但当前未被管理的 easytier-core（上次异常退出的遗留，
    /// 包含旧版本“授权一次性 root core”）。守护进程管理的 core 位于 /Library/PrivilegedHelperTools，不会被误判。
    func orphanedCorePIDs() -> [Int32] {
        guard let output = runPS() else { return [] }
        let managed = Set(running.values.compactMap { $0.process?.processIdentifier })
        var pids = Set<Int32>()

        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let space = text.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(text[..<space]),
                  pid > 1 else { continue }
            let command = String(text[text.index(after: space)...])
            guard command.contains("/Contents/Helpers/easytier-core --disable-env-parsing"),
                  !command.contains("/bin/sh -c"),
                  command.contains("Application Support/MacEasyTier/networks"),
                  !managed.contains(pid) else { continue }
            pids.insert(pid)
        }
        return pids.sorted()
    }

    /// 结束遗留 core：自己的进程直接结束，root 进程合并成一次管理员授权。返回实际结束的数量。
    func cleanupOrphanedCores() async -> Int {
        let pids = orphanedCorePIDs()
        guard !pids.isEmpty else { return 0 }

        var needsPrivilege: [Int32] = []
        for pid in pids {
            if kill(pid, SIGTERM) != 0, errno == EPERM { needsPrivilege.append(pid) }
        }
        if !needsPrivilege.isEmpty {
            let list = needsPrivilege.map(String.init).joined(separator: " ")
            try? await PrivilegedHelper.runPrivileged(
                "/bin/kill -TERM \(list) 2>/dev/null; /bin/sleep 1; /bin/kill -KILL \(list) 2>/dev/null; true",
                prompt: "MacEasyTier 需要结束遗留的 root easytier-core。"
            )
        }
        try? await Task.sleep(for: .milliseconds(300))
        for pid in pids where processAlive(pid) {
            kill(pid, SIGKILL)
        }
        try? await Task.sleep(for: .milliseconds(200))
        return pids.filter { !processAlive($0) }.count
    }

    private func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private func processAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Logs

    private func readLogs(id: UUID, logURL: URL) {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        var offset = logOffsets[id] ?? 0
        do {
            // 日志被截断（清空日志）后从头读。
            let size = try handle.seekToEnd()
            if size < offset { offset = 0 }
            try handle.seek(toOffset: offset)
            // 单次最多读 512 KB，避免极端刷屏时卡住主 actor。
            let data = try handle.read(upToCount: 512 * 1024) ?? Data()
            guard !data.isEmpty else { return }
            logOffsets[id] = offset + UInt64(data.count)
            let text = String(decoding: data, as: UTF8.self)
            var lines = logs[id] ?? []
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
            if lines.count > 5000 {
                lines.removeFirst(lines.count - 5000)
            }
            logs[id] = lines
        } catch {
            return
        }
    }

    private func tailLog(id: UUID) -> String {
        if let core = running[id] { readLogs(id: id, logURL: core.logURL) }
        let lines = (logs[id] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let ignored = [
            "peer rpc transport read aborted",
            "join_joinset_background",
            "close time.",
            "Retained buckets:",
            "new origin=\"rpc server\"",
        ]
        let important = lines.filter { line in
            guard !ignored.contains(where: { line.contains($0) }) else { return false }
            return line.contains("ERROR")
                || line.contains("PANIC")
                || line.contains("error=")
                || line.localizedCaseInsensitiveContains("failed to listen")
                || line.localizedCaseInsensitiveContains("Can't assign")
                || line.localizedCaseInsensitiveContains("permission denied")
                || line.localizedCaseInsensitiveContains("panicked")
        }
        return important.suffix(5).joined(separator: "\n")
    }
}
