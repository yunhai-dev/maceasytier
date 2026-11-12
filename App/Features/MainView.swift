import SwiftUI

/// 主窗口：侧边栏（网络分组）+ 网络列表 + Inspector + 连接条。
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            switch model.sidebarSelection {
            case .overview:
                DashboardView()
            default:
                if model.store.profiles.isEmpty {
                    emptyState
                } else {
                    NetworkListView(selection: model.sidebarSelection)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $model.showEditor) {
            NetworkEditor(
                profile: model.editingProfileID.flatMap(model.store.profile),
                secret: model.editingProfileID.map(model.store.secret(for:)) ?? ""
            )
            .id(model.editingProfileID)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 42))
            Text("加入 EasyTier 网络").font(.title2.bold())
        } description: {
            Text("填写网络名称、密钥，以及公共节点或对等节点地址。新建配置默认以客户端身份加入网络；服务端模式只是可选的高级用法。")
        } actions: {
            Button("加入网络") { model.beginNewProfile() }
                .prominentButtonStyle()
        }
    }
}
