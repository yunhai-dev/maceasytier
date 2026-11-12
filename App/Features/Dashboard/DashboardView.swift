import AppKit
import Charts
import SwiftUI

/// 首页概览：汇总流量、连接、内存与网络分布。
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var orphanCount = 0
    @State private var cleanupMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if orphanCount > 0 {
                    orphanBanner
                }
                if let profile = model.profilesMissingVirtualIP.first {
                    missingIPBanner(profile)
                }
                if model.store.profiles.isEmpty {
                    joinBanner
                }
                summaryCard
                HStack(alignment: .top, spacing: 8) {
                    trendCard
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        activePeersCard
                        memoryCard(
                            title: "内核内存",
                            icon: "memorychip",
                            color: .pink,
                            value: model.coreMemoryBytes
                        )
                        .help("easytier-core 的物理内存占用")
                        memoryCard(
                            title: "应用内存",
                            icon: "square.stack.3d.up",
                            color: .orange,
                            value: model.appMemoryBytes
                        )
                        .help("MacEasyTier 的物理内存占用（phys_footprint，不含共享库缓存）")
                    }
                    .frame(width: 200)
                }
                HStack(alignment: .top, spacing: 8) {
                    distributionCard
                        .frame(maxWidth: .infinity)
                    networksCard
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(.top)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { orphanCount = model.core.orphanedCorePIDs().count }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("首页")
        .toolbar {
            ToolbarItem {
                Button { model.beginNewProfile() } label: {
                    Label("加入网络", systemImage: "plus")
                }
                .help("创建新的网络配置（⌘N）")
            }
        }
    }

    // MARK: - Cards

    private var orphanBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到 \(orphanCount) 个残留 easytier-core")
                    .font(.subheadline.weight(.semibold))
                Text(cleanupMessage ?? "上次异常退出或旧版本遗留的 core 仍在运行，会占用端口并让新网络拿不到 IP。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("清理") {
                Task {
                    let cleaned = await model.core.cleanupOrphanedCores()
                    orphanCount = model.core.orphanedCorePIDs().count
                    cleanupMessage = cleaned > 0
                        ? "已结束 \(cleaned) 个残留核心。"
                        : "未能清理，可能取消了管理员授权。"
                }
            }
            .controlSize(.small)
        }
        .cardBackground()
    }

    private func missingIPBanner(_ profile: NetworkProfile) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "network.slash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("网络已连接，但未分配虚拟 IP")
                    .font(.subheadline.weight(.semibold))
                Text("已自动重试（重启核心、应用侧选址）仍未拿到地址。请在日志中查看原因，或在「\(profile.name)」中关闭 DHCP 并填写静态 IPv4，例如 10.144.144.4/24。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("编辑网络") { model.editProfile(profile.id) }
                .controlSize(.small)
        }
        .cardBackground()
    }

    private var joinBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有网络").font(.subheadline.weight(.semibold))
                Text("使用网络名称、密钥和公共节点加入一个 EasyTier 网络。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("加入网络") { model.beginNewProfile() }
                .prominentButtonStyle()
        }
        .cardBackground()
    }

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryStat(
                title: "总下载",
                value: TrafficStats.bytes(model.usage.totalRx),
                icon: "arrow.down.circle.fill",
                color: .blue
            )
            summaryDivider
            summaryStat(
                title: "总上传",
                value: TrafficStats.bytes(model.usage.totalTx),
                icon: "arrow.up.circle.fill",
                color: .red
            )
            summaryDivider
            summaryStat(
                title: "对等节点",
                value: "\(model.aggregatePeers)",
                icon: "point.3.connected.trianglepath.dotted",
                color: .teal
            )
            summaryDivider
            summaryStat(
                title: "路由条目",
                value: "\(model.aggregateRoutes)",
                icon: "arrow.triangle.branch",
                color: .purple
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .cardBackground()
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 24)
            .padding(.horizontal, 5)
    }

    private func summaryStat(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("流量趋势").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.blue)
            }
            .font(.caption.weight(.medium))

            HStack(alignment: .top, spacing: 22) {
                rateSummary(
                    icon: "arrow.down",
                    color: .blue,
                    rate: TrafficStats.rate(model.latestRxRate),
                    total: TrafficStats.bytes(model.aggregateTraffic.rxBytes)
                )
                rateSummary(
                    icon: "arrow.up",
                    color: .red,
                    rate: TrafficStats.rate(model.latestTxRate),
                    total: TrafficStats.bytes(model.aggregateTraffic.txBytes)
                )
            }

            if model.trafficHistory.count < 2 || !hasTrafficData {
                Text("暂无流量数据，启动网络后开始采集。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(model.trafficHistory) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("下载", point.rxRate)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.22), .blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("下载", point.rxRate)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("上传", point.txRate)
                    )
                    .foregroundStyle(.red.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let rate = value.as(Double.self) {
                                Text(TrafficStats.rate(rate))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 140)
            }
        }
        .cardBackground()
    }

    private var hasTrafficData: Bool {
        model.trafficHistory.contains { $0.rxRate > 0 || $0.txRate > 0 }
    }

    private func rateSummary(icon: String, color: Color, rate: String, total: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(rate)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Text(total)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var activePeersCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("活跃对等节点").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "link").foregroundStyle(.teal)
            }
            .font(.caption.weight(.medium))
            Text("\(model.aggregatePeers)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("\(model.runningCount) 个网络运行中")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardBackground()
    }

    private func memoryCard(title: String, icon: String, color: Color, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            .font(.caption.weight(.medium))
            Text(TrafficStats.bytes(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .cardBackground()
    }

    private var distributionCard: some View {
        let rx = model.aggregateTraffic.rxBytes
        let tx = model.aggregateTraffic.txBytes
        let total = rx + tx
        let rxRatio = total == 0 ? 0 : Double(rx) / Double(total)
        let txRatio = total == 0 ? 0 : Double(tx) / Double(total)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("本次流量分布").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "chart.bar.fill").foregroundStyle(.purple)
                }
                .font(.caption.weight(.medium))
                Spacer()
                Text("本次")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }

            Text(TrafficStats.bytes(total))
                .font(.system(size: 17, weight: .semibold, design: .rounded))

            GeometryReader { geometry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.blue)
                        .frame(width: max(0, geometry.size.width * rxRatio - 2))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.red)
                        .frame(width: max(0, geometry.size.width * txRatio - 2))
                }
            }
            .frame(height: 8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))

            HStack(spacing: 20) {
                legend(color: .blue, title: "下载", value: rx)
                legend(color: .red, title: "上传", value: tx)
                Spacer()
            }
        }
        .cardBackground()
    }

    private func legend(color: Color, title: String, value: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(TrafficStats.bytes(value))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var networksCard: some View {
        let profiles = model.store.profiles.sorted {
            let leftRunning = model.core.isRunning($0.id)
            let rightRunning = model.core.isRunning($1.id)
            if leftRunning != rightRunning { return leftRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("我的网络").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "network").foregroundStyle(.indigo)
                }
                .font(.caption.weight(.medium))

                Spacer()

                if !profiles.isEmpty {
                    Button("全部网络") { model.sidebarSelection = .all }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if profiles.isEmpty {
                HStack(spacing: 10) {
                    Text("还没有网络").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("加入网络") { model.beginNewProfile() }
                        .controlSize(.small)
                        .prominentButtonStyle()
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                VStack(spacing: 2) {
                    ForEach(profiles) { profile in
                        networkRow(profile)
                    }
                }
            }
        }
        .cardBackground()
    }

    private func networkRow(_ profile: NetworkProfile) -> some View {
        let state = model.state(for: profile)
        let running = model.core.isRunning(profile.id)
        let canToggle = !profile.isDisabled && state.status != .starting && state.status != .stopping
        let traffic = model.traffic(for: profile)

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(state.status))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .font(.callout)
                        .lineLimit(1)
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(subtitle(profile, state: state, running: running))
                    .font(.caption2)
                    .foregroundStyle(state.status == .failed ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if running {
                Text(TrafficStats.bytes(traffic.rxBytes + traffic.txBytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("", isOn: Binding(
                get: { running || state.status == .starting },
                set: { enabled in
                    if enabled {
                        model.startProfile(profile)
                    } else {
                        model.stopProfile(profile.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.green)
            .disabled(!canToggle)
            .help(running || state.status == .starting ? "关闭 \(profile.name)" : "打开 \(profile.name)")
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .contextMenu {
            Button("编辑…") { model.editProfile(profile.id) }
            Button(running ? "关闭网络" : "打开网络") { model.toggleProfile(profile.id) }
                .disabled(!canToggle)
        }
    }

    private func subtitle(_ profile: NetworkProfile, state: CoreState, running: Bool) -> String {
        if state.status == .failed, let error = state.error, !error.isEmpty {
            return error.split(separator: "\n").first.map(String.init) ?? error
        }
        if running {
            let peers = model.peerCount(for: profile)
            return "\(model.virtualIP(for: profile)) · \(peers) 个节点"
        }
        if profile.isDisabled {
            return "已禁用"
        }
        return "已停止"
    }

    private func statusColor(_ status: CoreStatus) -> Color {
        switch status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

}

private extension View {
    func cardBackground() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
    }
}
