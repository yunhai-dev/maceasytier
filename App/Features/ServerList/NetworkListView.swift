import SwiftUI

/// 网络列表：搜索 + 工具栏 + 表格 + 连接条 + Inspector。
struct NetworkListView: View {
    @Environment(AppModel.self) private var model
    let selection: SidebarItem
    @State private var pendingDelete: UUID?

    init(selection: SidebarItem) {
        self.selection = selection
    }

    var body: some View {
        @Bindable var model = model
        let rows = model.visibleProfiles

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Table(rows, selection: $model.selectedProfileIDs) {
                    TableColumn("名称") { (row: NetworkProfile) in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor(for: row))
                                .frame(width: 7, height: 7)
                            Text(row.name)
                                .lineLimit(1)
                                .fontWeight(model.core.isRunning(row.id) ? .semibold : .regular)
                            if row.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            if row.isDisabled {
                                Text("已禁用")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 140, ideal: 200)

                    TableColumn("状态") { (row: NetworkProfile) in
                        Text(model.state(for: row).status.title)
                            .foregroundStyle(statusColor(for: row))
                    }
                    .width(min: 70, ideal: 84)

                    TableColumn("网络") { (row: NetworkProfile) in
                        Text(row.config.networkName.isEmpty ? "—" : row.config.networkName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("虚拟 IP") { (row: NetworkProfile) in
                        Text(model.virtualIP(for: row))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(model.core.isRunning(row.id) ? .primary : .tertiary)
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("节点数") { (row: NetworkProfile) in
                        Text(model.core.isRunning(row.id) ? "\(model.peerCount(for: row))" : "—")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 50, ideal: 60)
                    .alignment(.trailing)

                    TableColumn("流量") { (row: NetworkProfile) in
                        Text(model.core.isRunning(row.id) ? model.traffic(for: row).displayText : "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 130, ideal: 160)
                    .alignment(.trailing)
                }
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView("无匹配结果", systemImage: "magnifyingglass", description: Text("换个关键词试试。"))
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first {
                        Button("编辑…") { model.editProfile(id) }
                        Button(model.core.isRunning(id) ? "停止" : "启动") { model.toggleProfile(id) }
                        Divider()
                        Button("复制") { model.store.duplicateProfile(id: id) }
                        Button("删除…", role: .destructive) { pendingDelete = id }
                    }
                } primaryAction: { ids in
                    if let id = ids.first {
                        model.toggleProfile(id)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { ConnectionBar() }

            if model.store.showInspector, model.selectedProfile != nil {
                InspectorView(profile: model.selectedProfile)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .overlay(alignment: .leading) { Divider() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selectedProfile != nil)
        .searchable(text: $model.searchText, prompt: "搜索网络")
        .confirmationDialog(
            "删除网络？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let pendingDelete { model.deleteProfile(pendingDelete) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("将删除该配置及其保存在钥匙串中的网络密钥。")
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.beginNewProfile() } label: {
                    Label("新建网络", systemImage: "plus")
                }
                .help("新建网络配置（⌘N）")

                Button {
                    if let profile = model.selectedProfile { model.toggleProfile(profile.id) }
                } label: {
                    Label("启动或停止", systemImage: "power")
                }
                .disabled(model.selectedProfile == nil)
                .help("启动或停止所选网络")

                Button { model.store.showInspector.toggle() } label: {
                    Label("检查器", systemImage: "sidebar.right")
                }
                .disabled(model.selectedProfile == nil)
                .help(model.selectedProfile == nil ? "选择网络后显示检查器" : "显示或隐藏检查器（⌘I）")
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        switch selection {
        case .overview: "首页"
        case .all: "全部网络"
        case .favorites: "收藏"
        case let .group(id): model.store.groups.first { $0.id == id }?.name ?? "网络"
        }
    }

    private func statusColor(for profile: NetworkProfile) -> Color {
        switch model.state(for: profile).status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
