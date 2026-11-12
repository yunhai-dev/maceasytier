import AppKit
import SwiftUI

/// 菜单栏面板：快速启停网络、打开窗口、退出。
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(model.store.profiles) { profile in
            Button {
                model.toggleProfile(profile.id)
            } label: {
                Label(
                    "\(statusTitle(profile)) — \(profile.name)",
                    systemImage: model.core.isRunning(profile.id) ? "stop.fill" : "play.fill"
                )
            }
        }

        if model.store.profiles.isEmpty {
            Text("还没有网络")
        }

        Divider()

        Button("打开 MacEasyTier") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Button("路由") { openWindow(id: "routes") }
        Button("日志") { openWindow(id: "logs") }
        Button("设置…") {
            NSApp.activate()
            openSettings()
        }

        Divider()

        Button("退出 MacEasyTier") {
            model.shutdown()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func statusTitle(_ profile: NetworkProfile) -> String {
        let state = model.state(for: profile)
        if state.status == .running {
            let peers = model.peerCount(for: profile)
            return "\(state.status.title) (\(peers))"
        }
        return state.status.title
    }
}
