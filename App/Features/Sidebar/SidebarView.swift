import SwiftUI

/// 侧边栏：全部网络、收藏、自定义分组；底部进入路由和设置。
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroupID: UUID?
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model

        List(selection: $model.sidebarSelection) {
            Label("首页", systemImage: "house")
                .tag(SidebarItem.overview)

            Label("全部网络", systemImage: "square.stack.3d.up")
                .badge(model.store.profiles.count)
                .tag(SidebarItem.all)

            Label("收藏", systemImage: "star")
                .badge(model.store.profiles.filter(\.isFavorite).count)
                .tag(SidebarItem.favorites)

            Section {
                ForEach(model.store.groups.filter(\.isManual)) { group in
                    SidebarGroupRow(group: group, count: count(for: group.id))
                        .tag(SidebarItem.group(group.id))
                        .contextMenu {
                            Button("重命名…") {
                                renameText = group.name
                                renamingGroupID = group.id
                            }
                            Button("删除", role: .destructive) {
                                if model.sidebarSelection == .group(group.id) {
                                    model.sidebarSelection = .all
                                }
                                model.store.deleteGroup(id: group.id)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("分组")
                    Spacer()
                    Button {
                        newGroupName = "分组 \(model.store.groups.count + 1)"
                        showNewGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("新建分组")
                }
            }

            if !runningProfiles.isEmpty {
                Section("运行中") {
                    ForEach(runningProfiles) { profile in
                        SidebarRunningRow(profile: profile)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarTools() }
        .alert("新建分组", isPresented: $showNewGroup) {
            TextField("名称", text: $newGroupName)
            Button("添加") { model.store.addGroup(name: newGroupName) }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "重命名分组",
            isPresented: Binding(
                get: { renamingGroupID != nil },
                set: { if !$0 { renamingGroupID = nil } }
            )
        ) {
            TextField("名称", text: $renameText)
            Button("重命名") {
                if let renamingGroupID { model.store.renameGroup(id: renamingGroupID, name: renameText) }
                renamingGroupID = nil
            }
            Button("取消", role: .cancel) { renamingGroupID = nil }
        }
    }

    private var runningProfiles: [NetworkProfile] {
        model.store.profiles.filter { model.core.isRunning($0.id) }
    }

    private func count(for groupID: UUID) -> Int {
        model.store.profiles.filter { $0.groupID == groupID }.count
    }
}

private struct SidebarGroupRow: View {
    let group: NetworkGroup
    let count: Int

    var body: some View {
        Label {
            Text(group.name)
        } icon: {
            Image(systemName: group.isManual ? "folder" : "dot.radiowaves.up.forward")
                .foregroundStyle(.tint)
        }
        .badge(count)
    }
}

private struct SidebarRunningRow: View {
    @Environment(AppModel.self) private var model
    let profile: NetworkProfile

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text(profile.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(model.virtualIP(for: profile))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
