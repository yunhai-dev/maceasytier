import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CoreSettings()
                .tabItem { Label("核心", systemImage: "cpu") }
                .tag(SettingsTab.core)
            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = model.store

        Form {
            Section("启动") {
                Text("在网络的编辑器中开启“启动时自动连接”后，应用启动时会自动连接该网络。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("登录时启动")
                    Spacer()
                    Text(loginStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(launchAtLogin ? "关闭" : "开启") { updateLoginItem(!launchAtLogin) }
                        .controlSize(.small)
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("日志") {
                Picker("日志级别", selection: $store.logLevel) {
                    ForEach(logLevels, id: \.0) { level in
                        Text(level.1).tag(level.0)
                    }
                }
                Text("下次启动网络时生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("窗口") {
                Toggle("显示检查器", isOn: $store.showInspector)
            }

            Section("运行状态") {
                LabeledContent("运行中的网络", value: "\(model.runningCount)")
            }

            if let error = store.lastError {
                Section("存储") {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("通用")
        .onAppear(perform: refreshLoginItem)
        .onChange(of: store.logLevel) { _, _ in store.save() }
        .onChange(of: store.showInspector) { _, _ in store.save() }
    }

    private let logLevels = [
        ("off", "关闭"),
        ("error", "错误"),
        ("warn", "警告"),
        ("info", "信息"),
        ("debug", "调试"),
        ("trace", "追踪"),
    ]

    private var loginStatusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已开启"
        case .requiresApproval: "需要批准"
        case .notRegistered: "已关闭"
        case .notFound: "不可用"
        @unknown default: "未知"
        }
    }

    private func refreshLoginItem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "无法更新登录项：\(error.localizedDescription)"
        }
        refreshLoginItem()
    }
}

private struct CoreSettings: View {
    @Environment(AppModel.self) private var model
    @State private var orphanCount = 0
    @State private var cleanupMessage: String?
    @State private var helperMessage: String?

    var body: some View {
        Form {
            Section("EasyTier 核心") {
                LabeledContent("easytier-core") {
                    Text(CLIBridge.locateCore()?.path ?? "未找到")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                LabeledContent("核心版本", value: model.core.coreVersion ?? "—")
            }

            Section("系统服务（TUN）") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        if model.core.helperBusy { ProgressView().controlSize(.small) }
                        Text(helperStatusText)
                            .foregroundStyle(helperStatusColor)
                    }
                }
                HStack {
                    Button(installButtonTitle) { install() }
                        .disabled(model.core.helperBusy || model.core.helperState == .ready)
                    Button("卸载") { uninstall() }
                        .disabled(model.core.helperBusy || model.core.helperState == .notInstalled)
                }
                .controlSize(.small)
                Text("TUN 网络由常驻系统服务（launchd 守护进程）以 root 运行 easytier-core。只需授权安装一次，之后启动/停止都不再弹密码，也更快。无 TUN 网络不需要它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let helperMessage {
                    Text(helperMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("运行") {
                Button("打开网络配置目录") {
                    NSWorkspace.shared.open(AppPaths.networksDirectory)
                }
                Button("重启运行中的网络") {
                    model.restartAll()
                }

                HStack {
                    Text("残留核心进程")
                    Spacer()
                    Text("\(orphanCount)")
                        .foregroundStyle(.secondary)
                    Button("清理") {
                        Task {
                            let before = orphanCount
                            let cleaned = await model.core.cleanupOrphanedCores()
                            orphanCount = model.core.orphanedCorePIDs().count
                            if cleaned > 0 {
                                cleanupMessage = "已结束 \(cleaned) 个残留核心。"
                            } else if before > 0 {
                                cleanupMessage = "未能清理，可能取消了管理员授权。"
                            } else {
                                cleanupMessage = "没有残留核心。"
                            }
                        }
                    }
                    .disabled(orphanCount == 0)
                }
                Text("旧版本（每次启动都要授权）或异常退出可能留下 root core，它们会占用端口并让新网络拿不到 IP，可在这里清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let cleanupMessage {
                    Text(cleanupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("核心")
        .onAppear {
            orphanCount = model.core.orphanedCorePIDs().count
            Task { await model.core.refreshHelperState() }
        }
    }

    private var helperStatusText: String {
        switch model.core.helperState {
        case .unknown: "检测中…"
        case .notInstalled: "未安装"
        case .ready: "已安装并运行"
        case .outdated: "需要更新"
        case let .unavailable(reason): reason
        }
    }

    private var helperStatusColor: Color {
        switch model.core.helperState {
        case .ready: .green
        case .outdated, .unavailable: .orange
        default: .secondary
        }
    }

    private var installButtonTitle: String {
        switch model.core.helperState {
        case .outdated, .unavailable: "更新"
        default: "安装"
        }
    }

    private func install() {
        helperMessage = nil
        Task {
            do { try await model.core.installHelper() } catch { helperMessage = error.localizedDescription }
        }
    }

    private func uninstall() {
        helperMessage = nil
        Task {
            do { try await model.core.uninstallHelper() } catch { helperMessage = error.localizedDescription }
        }
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("MacEasyTier", value: appVersion)
                LabeledContent("EasyTier 核心", value: model.core.coreVersion ?? "—")
                LabeledContent("许可", value: "MIT")
            }
            Section("EasyTier") {
                Text("EasyTier 使用 LGPL-3.0 许可。内置的 easytier-core 与 easytier-cli 为官方未修改版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("EasyTier GitHub 主页", destination: URL(string: "https://github.com/EasyTier/EasyTier")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("关于")
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
