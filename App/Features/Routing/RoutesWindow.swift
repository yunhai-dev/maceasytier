import SwiftUI

/// Routes 窗口：查看所选网络的实时路由表。
struct RoutesWindow: View {
    @Environment(AppModel.self) private var model
    @State private var profileID: UUID?
    @State private var search = ""
    @State private var style: Style = .topology

    private enum Style: String, CaseIterable, Identifiable {
        case topology
        case table

        var id: String { rawValue }

        var title: String {
            switch self {
            case .topology: "拓扑"
            case .table: "路由表"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 440)
        .searchable(text: $search, prompt: "搜索节点或路由")
        .onAppear(perform: selectDefaultProfile)
        .onChange(of: model.store.profiles) { _, _ in selectDefaultProfile() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("网络", selection: $profileID) {
                ForEach(model.store.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(model.store.profiles.isEmpty)

            Picker("显示", selection: $style) {
                ForEach(Style.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            if let profile {
                Text(model.state(for: profile).status.title)
                    .font(.caption)
                    .foregroundStyle(model.core.isRunning(profile.id) ? .green : .secondary)
                Text("\(rows.count) 条路由")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("复制表格", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tableText, forType: .string)
            }
            .disabled(rows.isEmpty)

            Button("刷新", systemImage: "arrow.clockwise") {
                model.core.refreshNow()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if style == .topology, let profile, model.core.isRunning(profile.id) {
            NetworkTopologyView(
                topology: NetworkTopology.build(
                    routes: allRoutes,
                    query: search,
                    publicRelay: profile.config.method == .publicServer ? profile.config.publicServer : nil
                ),
                peers: model.core.peers[profile.id] ?? []
            )
        } else if let profile, model.core.isRunning(profile.id) {
            Table(rows) {
                TableColumn("目标") { (route: RouteRow) in
                    Text(route.virtualIPv4)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 150)

                TableColumn("主机名") { (route: RouteRow) in
                    Text(route.hostname).lineLimit(1)
                }
                .width(min: 110, ideal: 160)

                TableColumn("代理网段") { (route: RouteRow) in
                    Text(route.proxyCIDRs.isEmpty ? "—" : route.proxyCIDRs)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 170)

                TableColumn("下一跳") { (route: RouteRow) in
                    Text(route.isLocal ? "本机" : (route.nextHopHostname == "DIRECT" ? "直连" : (route.nextHopHostname.isEmpty ? route.nextHop : route.nextHopHostname)))
                        .lineLimit(1)
                }
                .width(min: 90, ideal: 130)

                TableColumn("跳数") { (route: RouteRow) in
                    Text("\(route.cost)")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 45, ideal: 55)
                .alignment(.trailing)

                TableColumn("路径延迟") { (route: RouteRow) in
                    Text(String(format: "%.2f ms", route.pathLatencyMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 85, ideal: 100)
                .alignment(.trailing)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "暂无路由",
                        systemImage: "arrow.triangle.branch",
                        description: Text("发现对等节点或子网代理后会显示路由。")
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        } else {
            ContentUnavailableView(
                "网络未运行",
                systemImage: "play.slash",
                description: Text(profile == nil ? "请先创建一个网络配置。" : "启动所选网络后查看路由。")
            )
        }
    }

    private var profile: NetworkProfile? {
        guard let profileID else { return nil }
        return model.store.profile(id: profileID)
    }

    private var allRoutes: [RouteRow] {
        guard let profileID else { return [] }
        return model.core.routes[profileID] ?? []
    }

    private var rows: [RouteRow] {
        let all = allRoutes
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.virtualIPv4.localizedCaseInsensitiveContains(query)
                || $0.proxyCIDRs.localizedCaseInsensitiveContains(query)
        }
    }

    private var tableText: String {
        let header = "目标\t主机名\t代理网段\t下一跳\t跳数\t路径延迟(ms)"
        let rows = rows.map {
            "\($0.virtualIPv4)\t\($0.hostname)\t\($0.proxyCIDRs)\t\($0.nextHopHostname)\t\($0.cost)\t\(String(format: "%.2f", $0.pathLatencyMs))"
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func selectDefaultProfile() {
        if let profileID, model.store.profile(id: profileID) != nil { return }
        profileID = model.store.profiles.first(where: { model.core.isRunning($0.id) })?.id
            ?? model.store.profiles.first?.id
    }
}
