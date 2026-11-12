import SwiftUI

/// 右侧检查器：所选网络的运行状态、节点信息与配置摘要。
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let profile: NetworkProfile?

    var body: some View {
        Group {
            if let profile {
                Form {
                    Section { header(profile) }
                    statusSection(profile)
                    nodeSection(profile)
                    trafficSection(profile)
                    configSection(profile)
                    if let error = model.state(for: profile).error, !error.isEmpty {
                        Section("错误") {
                            Text(error)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "未选择网络",
                    systemImage: "sidebar.right",
                    description: Text("选择一个网络查看详情。")
                )
            }
        }
    }

    private func header(_ profile: NetworkProfile) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(profile.name)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(model.state(for: profile).status.title)
                .font(.caption)
                .foregroundStyle(statusColor(profile))
            HStack(spacing: 8) {
                Button(model.core.isRunning(profile.id) ? "停止" : "启动",
                       systemImage: model.core.isRunning(profile.id) ? "stop.fill" : "play.fill") {
                    model.toggleProfile(profile.id)
                }
                .prominentButtonStyle()

                Button("编辑", systemImage: "pencil") { model.editProfile(profile.id) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusSection(_ profile: NetworkProfile) -> some View {
        let state = model.state(for: profile)
        Section("状态") {
            LabeledContent("状态") {
                Text(state.status.title).foregroundStyle(statusColor(profile))
            }
            if let port = state.rpcPort {
                LabeledContent("RPC 端口") { Text("\(port)").monospaced() }
            }
            LabeledContent("TUN") {
                Text(profile.config.usesTUN ? "已启用" : "无 TUN")
            }
        }
    }

    @ViewBuilder
    private func nodeSection(_ profile: NetworkProfile) -> some View {
        let node = model.core.nodeInfo[profile.id]
        Section("本机节点") {
            LabeledContent("虚拟 IP") {
                Text(node?.displayVirtualIP ?? "—").monospaced()
            }
            LabeledContent("主机名") { Text(node?.hostname ?? profile.config.hostname) }
            if let node {
                LabeledContent("节点 ID") { Text("\(node.peerID)").monospaced() }
                LabeledContent("NAT") { Text(node.natType) }
                LabeledContent("版本") { Text(node.version).font(.caption.monospaced()) }
                if let publicIP = node.publicIP {
                    LabeledContent("公网 IP") { Text(publicIP).monospaced() }
                }
            }
            LabeledContent("对等节点") { Text("\(model.peerCount(for: profile))") }
        }
    }

    @ViewBuilder
    private func trafficSection(_ profile: NetworkProfile) -> some View {
        let traffic = model.traffic(for: profile)
        Section("流量") {
            LabeledContent("速率") { Text(traffic.displayText).font(.caption.monospaced()) }
            LabeledContent("总计") { Text(traffic.totalText).font(.caption.monospaced()) }
        }
    }

    private func configSection(_ profile: NetworkProfile) -> some View {
        Section("配置") {
            LabeledContent("网络名称") {
                Text(profile.config.networkName.isEmpty ? "—" : profile.config.networkName)
                    .lineLimit(1)
            }
            LabeledContent("模式") { Text(profile.config.method.title) }
            if let port = profile.config.socks5Port {
                LabeledContent("SOCKS5") { Text("127.0.0.1:\(port)").monospaced() }
            }
            if profile.config.enableExitNode {
                LabeledContent("出口节点") { Text("已启用") }
            }
            if !profile.config.proxyNetworks.isEmpty {
                LabeledContent("代理网段") {
                    Text(profile.config.proxyNetworks.map(\.cidr).joined(separator: ", "))
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
            }
            if !profile.config.listeners.isEmpty {
                LabeledContent("监听地址") {
                    Text(profile.config.listeners.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .lineLimit(3)
                }
            }
            HStack {
                CopyButton("复制网络名称", systemImage: "doc.on.doc") { profile.config.networkName }
                Button("路由", systemImage: "arrow.triangle.branch") { openWindow(id: "routes") }
            }
        }
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
