import Foundation
import Observation
import SwiftUI

/// 全局状态：网络配置、运行实例、选择与窗口请求。
@MainActor
@Observable
final class AppModel {
    let store: NetworkStore
    let core: CoreSupervisor
    let usage = UsageLedger()

    var trafficHistory: [TrafficPoint] = []
    var appMemoryBytes: UInt64 = 0
    private var dashboardTask: Task<Void, Never>?

    var sidebarSelection: SidebarItem = .overview
    var selectedProfileIDs: Set<UUID> = []
    var searchText: String = ""
    var settingsTab: SettingsTab = .general

    var showEditor = false
    var editingProfileID: UUID?

    var didStartup = false

    init(store: NetworkStore = NetworkStore(), core: CoreSupervisor = CoreSupervisor()) {
        self.store = store
        self.core = core
        AppDelegate.model = self
        core.onLeaseChange = { [weak store] id, ip in
            store?.setLease(ip, for: id)
        }

        Task { [weak self] in
            await self?.startup()
        }
        startDashboardSampling()
    }

    // MARK: - Derived

    var visibleProfiles: [NetworkProfile] {
        store.visibleProfiles(selection: sidebarSelection, searchText: searchText)
    }

    var selectedProfile: NetworkProfile? {
        guard selectedProfileIDs.count == 1, let id = selectedProfileIDs.first else { return nil }
        return store.profile(id: id)
    }

    var activeProfile: NetworkProfile? {
        if let selected = selectedProfile {
            return selected
        }
        return store.profiles.first { core.isRunning($0.id) }
    }

    var runningCount: Int {
        core.running.count
    }

    var aggregateTraffic: TrafficStats {
        var total = TrafficStats()
        for stats in core.traffic.values {
            total.rxBytes += stats.rxBytes
            total.txBytes += stats.txBytes
            total.rxRate += stats.rxRate
            total.txRate += stats.txRate
        }
        // stats 计数器不可用时，用 peer 字节数兜底，避免首页全部显示 0。
        if total.rxBytes == 0 && total.txBytes == 0 {
            for rows in core.peers.values {
                for peer in rows {
                    total.rxBytes += peer.rxBytes
                    total.txBytes += peer.txBytes
                }
            }
        }
        return total
    }

    var latestRxRate: Double {
        trafficHistory.last?.rxRate ?? 0
    }

    var latestTxRate: Double {
        trafficHistory.last?.txRate ?? 0
    }

    var aggregatePeers: Int {
        core.peers.values.reduce(0) { $0 + $1.count }
    }

    var aggregateRoutes: Int {
        core.routes.values.reduce(0) { $0 + $1.count }
    }

    var coreMemoryBytes: UInt64 {
        core.memoryFootprintBytes
    }

    var menuBarSymbol: String {
        if store.profiles.contains(where: { core.state(for: $0.id).status == .failed }) {
            return "exclamationmark.triangle"
        }
        if runningCount > 0 {
            return "point.3.connected.trianglepath.dotted"
        }
        return "point.3.connected.trianglepath.dotted"
    }

    func groupName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return store.groups.first { $0.id == id }?.name
    }

    // MARK: - Profile actions

    func beginNewProfile() {
        editingProfileID = nil
        showEditor = true
    }

    func editProfile(_ id: UUID) {
        editingProfileID = id
        showEditor = true
    }

    func saveProfile(_ profile: NetworkProfile, secret: String) {
        if store.profile(id: profile.id) == nil {
            store.addProfile(profile, secret: secret)
        } else {
            store.updateProfile(profile, secret: secret)
        }
    }

    func deleteProfile(_ id: UUID) {
        Task {
            await core.remove(id: id)
            store.deleteProfile(id: id)
            selectedProfileIDs.remove(id)
        }
    }

    func toggleProfile(_ id: UUID) {
        guard let profile = store.profile(id: id) else { return }
        if core.isRunning(id) {
            stopProfile(id)
        } else {
            startProfile(profile)
        }
    }

    func stopProfile(_ id: UUID) {
        Task { await core.stop(id: id) }
    }

    func startProfile(_ profile: NetworkProfile) {
        guard !profile.isDisabled else { return }
        let secret = store.secret(for: profile.id)
        Task {
            await core.start(profile: profile, secret: secret, logLevel: store.logLevel)
        }
    }

    func startAll() {
        for profile in store.profiles where !profile.isDisabled {
            startProfile(profile)
        }
    }

    func stopAll() {
        Task {
            for id in Array(core.running.keys) {
                await core.stop(id: id)
            }
        }
    }

    /// 逐个重启运行中的网络（先全部停止，再启动）。
    func restartAll() {
        let profiles = store.profiles.filter { core.isRunning($0.id) }
        Task {
            for profile in profiles {
                await core.stop(id: profile.id)
            }
            for profile in profiles {
                startProfile(profile)
            }
        }
    }

    func startup() async {
        guard !didStartup else { return }
        didStartup = true

        // 单元测试会以 App 为 host 启动，避免测试时拉起用户的网络。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        await core.refreshHelperState()
        for profile in store.profiles where profile.autoConnect && !profile.isDisabled {
            await core.start(profile: profile, secret: store.secret(for: profile.id), logLevel: store.logLevel)
        }
    }

    func shutdown() {
        usage.flush()
        core.shutdown()
    }

    // MARK: - Formatting

    func state(for profile: NetworkProfile) -> CoreState {
        core.state(for: profile.id)
    }

    func peerCount(for profile: NetworkProfile) -> Int {
        core.peers[profile.id]?.count ?? 0
    }

    func virtualIP(for profile: NetworkProfile) -> String {
        guard let ip = core.nodeInfo[profile.id]?.displayVirtualIP, !ip.isEmpty else {
            guard core.isRunning(profile.id) else { return "—" }
            switch core.ipPhase[profile.id] {
            case .failed: return "未分配"
            default: return core.peers[profile.id]?.isEmpty == false ? "获取中…" : "等待节点…"
            }
        }
        return ip
    }

    /// 已运行但 IP 自动恢复也失败的网络（才需要提示用户）。
    var profilesMissingVirtualIP: [NetworkProfile] {
        store.profiles.filter { profile in
            core.state(for: profile.id).status == .running && core.ipPhase[profile.id] == .failed
        }
    }

    func traffic(for profile: NetworkProfile) -> TrafficStats {
        core.traffic[profile.id] ?? TrafficStats()
    }

    // MARK: - Dashboard sampling

    private func startDashboardSampling() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        dashboardTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.sampleDashboard()
            }
        }
    }

    func sampleDashboard() {
        let traffic = aggregateTraffic
        usage.update(rx: traffic.rxBytes, tx: traffic.txBytes)

        trafficHistory.append(
            TrafficPoint(
                date: Date(),
                rxRate: traffic.rxRate,
                txRate: traffic.txRate
            )
        )
        if trafficHistory.count > 180 {
            trafficHistory.removeFirst(trafficHistory.count - 180)
        }
        appMemoryBytes = easytier_current_footprint()
    }
}
