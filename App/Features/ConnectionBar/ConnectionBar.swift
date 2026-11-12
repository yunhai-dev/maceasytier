import SwiftUI

/// 底部连接条：启停当前网络、显示状态/流量、复制 SOCKS5 地址、进入路由和日志。
struct ConnectionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let profile = model.activeProfile

        CompatGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                connectButton(profile)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.name ?? "未选择网络")
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(profile))
                        .font(.caption)
                        .foregroundStyle(profile.map(statusColor) ?? .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let profile, model.core.isRunning(profile.id) {
                    Text(model.traffic(for: profile).displayText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                if let profile, let port = profile.config.socks5Port, model.core.isRunning(profile.id) {
                    CopyButton("SOCKS5", systemImage: "doc.on.doc") { "127.0.0.1:\(port)" }
                        .help("复制本地 SOCKS5 地址")
                }

                Text(profile?.config.usesTUN == true ? "TUN" : "无 TUN")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: .capsule)

                Menu {
                    Button("路由") { openWindow(id: "routes") }
                    Button("日志") { openWindow(id: "logs") }
                    Divider()
                    if let profile {
                        Button("编辑网络…") { model.editProfile(profile.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 0, maxWidth: .infinity)
            .glassSurface(in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func connectButton(_ profile: NetworkProfile?) -> some View {
        Button {
            guard let profile else { return }
            model.toggleProfile(profile.id)
        } label: {
            Image(systemName: profile.map { model.core.isRunning($0.id) ? "stop.fill" : "play.fill" } ?? "power")
                .font(.title3.weight(.semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .glassSurface(in: .circle)
        .disabled(profile == nil)
        .help(profile.map { model.core.isRunning($0.id) ? "停止 \($0.name)" : "启动 \($0.name)" } ?? "请先选择网络")
        .accessibilityLabel("启动或停止网络")
    }

    private func subtitle(_ profile: NetworkProfile?) -> String {
        guard let profile else { return "新建一个网络开始使用" }
        let state = model.state(for: profile)
        if let error = state.error, state.status == .failed {
            return error.split(separator: "\n").first.map(String.init) ?? error
        }
        if state.status == .running {
            let ip = model.virtualIP(for: profile)
            let peers = model.peerCount(for: profile)
            return "\(profile.config.networkName) · \(ip) · \(peers) 个节点"
        }
        return state.status.title
    }

    private func statusColor(_ profile: NetworkProfile) -> Color {
        switch model.state(for: profile).status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
