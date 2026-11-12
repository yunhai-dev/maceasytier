import AppKit
import Darwin
import SwiftUI

@main
struct MacEasyTierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacEasyTier", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 760)
        .launchSuppressed(false)
        .commands { AppCommands(model: model) }

        Window("路由", id: "routes") {
            RoutesWindow()
                .environment(model)
        }
        .defaultSize(width: 980, height: 600)
        .launchSuppressed()

        Window("日志", id: "logs") {
            LogView()
                .environment(model)
        }
        .defaultSize(width: 860, height: 500)
        .launchSuppressed()

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()

        // pkill / 系统终止时也走正常退出流程，停止 root core。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建网络…") { model.beginNewProfile() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("启动所选网络") {
                if let profile = model.selectedProfile { model.startProfile(profile) }
            }
            Button("停止所选网络") {
                if let profile = model.selectedProfile { model.stopProfile(profile.id) }
            }
            Divider()
            Button("启动全部网络") { model.startAll() }
            Button("停止全部网络") { model.stopAll() }
        }
        CommandGroup(after: .sidebar) {
            Button("显示检查器") {
                model.store.showInspector.toggle()
            }
            .keyboardShortcut("i")
        }
        CommandGroup(after: .windowArrangement) {
            Button("显示路由") { openWindow(id: "routes") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("显示日志") { openWindow(id: "logs") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("设置…") { openSettings() }
                .keyboardShortcut(",")
        }
    }
}
