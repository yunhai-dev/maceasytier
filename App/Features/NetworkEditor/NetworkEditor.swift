import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络配置编辑器：表单 + TOML 导入/导出/校验。
struct NetworkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var profile: NetworkProfile
    @State private var secret: String
    @State private var peerText: String
    @State private var listenerText: String
    @State private var proxyNetworkText: String
    @State private var routeText: String
    @State private var exitNodeText: String
    @State private var portForwardText: String
    @State private var socks5Enabled: Bool
    @State private var socks5PortText: String

    @State private var showAdvanced = false
    @State private var errors: [String] = []
    @State private var validationMessage: String?
    @State private var isValidating = false

    init(profile: NetworkProfile?, secret: String) {
        let base = profile ?? NetworkProfile()
        _profile = State(initialValue: base)
        _secret = State(initialValue: secret)
        _peerText = State(initialValue: base.config.peers.joined(separator: "\n"))
        _listenerText = State(initialValue: base.config.listeners.joined(separator: "\n"))
        _proxyNetworkText = State(initialValue: base.config.proxyNetworks.map { network in
            network.mappedCIDR.isEmpty ? network.cidr : "\(network.cidr) -> \(network.mappedCIDR)"
        }.joined(separator: "\n"))
        _routeText = State(initialValue: base.config.manualRoutes.joined(separator: "\n"))
        _exitNodeText = State(initialValue: base.config.exitNodes.joined(separator: "\n"))
        _portForwardText = State(initialValue: base.config.portForwards.map {
            "\($0.proto) \($0.bindAddress) \($0.destination)"
        }.joined(separator: "\n"))
        _socks5Enabled = State(initialValue: base.config.socks5Port != nil)
        _socks5PortText = State(initialValue: base.config.socks5Port.map(String.init) ?? "1080")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                basics
                addressing
                advancedSection
                if !errors.isEmpty {
                    Section("校验") {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        if errors.contains(where: { $0.contains("不属于本机") }) {
                            Button("监听地址改为 0.0.0.0", systemImage: "wrench.and.screwdriver") {
                                normalizeListenerHosts()
                            }
                        }
                    }
                }
                if let validationMessage {
                    Section("配置检查") {
                        Text(validationMessage)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(
                            validationMessage.hasPrefix("校验通过")
                                || validationMessage.hasPrefix("已导入")
                                || validationMessage.hasPrefix("已导出")
                                ? .green
                                : .red
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 620, height: 620)
    }

    // MARK: - Sections

    private var basics: some View {
        Section("网络") {
            TextField("名称", text: $profile.name)
            Picker("分组", selection: $profile.groupID) {
                Text("无").tag(UUID?.none)
                ForEach(model.store.groups) { group in
                    Text(group.name).tag(Optional(group.id))
                }
            }
            TextField("网络名称", text: $profile.config.networkName)
            SecureField("网络密钥", text: $secret)
            TextField("实例名称", text: $profile.config.instanceName)
            TextField("主机名", text: $profile.config.hostname)

            Picker("加入方式", selection: $profile.config.method) {
                ForEach(NetworkingMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            Text(profile.config.method.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch profile.config.method {
            case .publicServer:
                TextField("公共节点地址", text: $profile.config.publicServer, prompt: Text(NetworkConfig.defaultPublicServer))
                Text("公共节点只负责节点发现和转发，网络名称与密钥用于识别网络。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .manual:
                multiline("对等节点地址", text: $peerText, hint: "每行一个地址，例如 tcp://10.0.0.2:11010")
                Text("客户端模式至少需要一个可连接的对等节点地址。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .standalone:
                Label("服务端模式：只监听，不会主动加入网络。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("启动时自动连接", isOn: $profile.autoConnect)
            Toggle("收藏", isOn: $profile.isFavorite)
            Toggle("禁用", isOn: $profile.isDisabled)
        }
    }

    private var addressing: some View {
        Section("本机") {
            if !profile.config.dhcp {
                TextField("虚拟 IPv4", text: $profile.config.virtualIPv4, prompt: Text("10.144.144.10/24"))
            }
            Toggle(
                "使用 TUN（需安装系统服务）",
                isOn: Binding(
                    get: { profile.config.usesTUN },
                    set: { profile.config.usesTUN = $0 }
                )
            )
            Text("TUN 会创建 utun 网卡，由常驻系统服务以 root 运行 easytier-core：首次启用只需授权一次，之后启停不再需要密码。关闭后使用无 TUN 模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级", isExpanded: $showAdvanced) {
                Toggle("不监听端口", isOn: $profile.config.noListener)
                if !profile.config.noListener {
                    multiline("监听地址", text: $listenerText, hint: "tcp://0.0.0.0:11010")
                    Text("客户端可选。监听地址必须是本机地址，使用 0.0.0.0，不要填公网 IP。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("延迟优先", isOn: $profile.config.advanced.latencyFirst)
                Toggle("禁用 P2P", isOn: $profile.config.advanced.disableP2P)
                Toggle("KCP 代理", isOn: $profile.config.advanced.enableKCPProxy)
                Toggle("QUIC 代理", isOn: $profile.config.advanced.enableQUICProxy)
                Toggle("允许本机作为出口节点", isOn: $profile.config.enableExitNode)
                Toggle("私有模式", isOn: $profile.config.advanced.privateMode)
                Toggle("魔法 DNS", isOn: $profile.config.advanced.acceptDNS)

                Picker("压缩算法", selection: $profile.config.advanced.compression) {
                    Text("无").tag("none")
                    Text("zstd").tag("zstd")
                }
                Picker("加密算法", selection: $profile.config.advanced.encryptionAlgorithm) {
                    ForEach(["aes-gcm", "aes-gcm-256", "chacha20", "xor"], id: \.self) { algorithm in
                        Text(algorithm).tag(algorithm)
                    }
                }

                TextField("MTU（0 为默认）", value: $profile.config.advanced.mtu, format: .number)
                TextField("中继网络白名单", text: $profile.config.advanced.relayNetworkWhitelist)

                Toggle("SOCKS5 服务", isOn: $socks5Enabled)
                if socks5Enabled {
                    TextField("SOCKS5 端口", text: $socks5PortText)
                }

                multiline("子网代理", text: $proxyNetworkText, hint: "10.1.1.0/24\n192.168.1.0/24 -> 10.2.2.0/24")
                multiline("手动路由", text: $routeText, hint: "10.1.1.0/24")
                multiline("出口节点", text: $exitNodeText, hint: "10.144.144.1")
                multiline("端口转发", text: $portForwardText, hint: "tcp 127.0.0.1:5202 10.144.0.20:5201")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("导入 TOML…") { importTOML() }
            Button("导出 TOML…") { exportTOML() }
            Button(isValidating ? "检查中…" : "检查配置") { checkConfig() }
                .disabled(isValidating)

            Spacer()

            Button("取消", role: .cancel) { dismiss() }
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .prominentButtonStyle()
        }
        .padding(12)
    }

    private func multiline(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 54, maxHeight: 80)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Actions

    private func save() {
        var config = profile.config
        config.peers = lines(peerText)
        config.listeners = lines(listenerText)
        config.socks5Port = socks5Enabled ? Int(socks5PortText) : nil
        config.proxyNetworks = parseProxyNetworks(proxyNetworkText)
        config.manualRoutes = lines(routeText)
        config.exitNodes = lines(exitNodeText)
        config.portForwards = parsePortForwards(portForwardText)
        profile.config = config

        let validation = TOMLCodec.validate(config)
        var allErrors = validation
        if socks5Enabled, Int(socks5PortText).map({ (1 ... 65535).contains($0) }) != true {
            allErrors.append("SOCKS5 端口必须在 1–65535 之间。")
        }
        guard allErrors.isEmpty else {
            errors = allErrors
            return
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.name = config.networkName.isEmpty ? "网络" : config.networkName
        }

        model.saveProfile(profile, secret: secret)
        dismiss()
    }

    private func checkConfig() {
        isValidating = true
        validationMessage = nil
        var config = profile.config
        config.peers = lines(peerText)
        config.listeners = lines(listenerText)
        config.socks5Port = socks5Enabled ? Int(socks5PortText) : nil
        config.proxyNetworks = parseProxyNetworks(proxyNetworkText)
        config.manualRoutes = lines(routeText)
        config.exitNodes = lines(exitNodeText)
        config.portForwards = parsePortForwards(portForwardText)

        let localErrors = TOMLCodec.validate(config)
        guard localErrors.isEmpty else {
            errors = localErrors
            isValidating = false
            return
        }
        errors = []

        var draft = profile
        draft.config = config
        let toml = TOMLCodec.render(draft, secret: secret)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maceasytier-check-\(UUID().uuidString).toml")

        Task {
            defer {
                isValidating = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                try Data(toml.utf8).write(to: url, options: .atomic)
                guard let core = CLIBridge.locateCore() else {
                    validationMessage = "未找到 easytier-core。"
                    return
                }
                try await CLIBridge.validate(configFile: url, core: core)
                validationMessage = "校验通过 — easytier-core 接受了该配置。"
            } catch {
                validationMessage = error.localizedDescription
            }
        }
    }

    private func importTOML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let imported = try TOMLCodec.parse(text)
            profile.name = imported.name
            profile.config = imported.config
            secret = imported.secret
            peerText = imported.config.peers.joined(separator: "\n")
            listenerText = imported.config.listeners.joined(separator: "\n")
            proxyNetworkText = imported.config.proxyNetworks.map {
                $0.mappedCIDR.isEmpty ? $0.cidr : "\($0.cidr) -> \($0.mappedCIDR)"
            }.joined(separator: "\n")
            routeText = imported.config.manualRoutes.joined(separator: "\n")
            exitNodeText = imported.config.exitNodes.joined(separator: "\n")
            portForwardText = imported.config.portForwards.map { "\($0.proto) \($0.bindAddress) \($0.destination)" }.joined(separator: "\n")
            socks5Enabled = imported.config.socks5Port != nil
            socks5PortText = imported.config.socks5Port.map(String.init) ?? "1080"
            errors = []
            validationMessage = "已导入 \(url.lastPathComponent)，检查字段后保存。"
        } catch {
            errors = ["无法导入 \(url.lastPathComponent)：\(error.localizedDescription)"]
        }
    }

    private func exportTOML() {
        var config = profile.config
        config.peers = lines(peerText)
        config.listeners = lines(listenerText)
        config.socks5Port = socks5Enabled ? Int(socks5PortText) : nil
        config.proxyNetworks = parseProxyNetworks(proxyNetworkText)
        config.manualRoutes = lines(routeText)
        config.exitNodes = lines(exitNodeText)
        config.portForwards = parsePortForwards(portForwardText)
        profile.config = config

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        panel.nameFieldStringValue = (profile.name.isEmpty ? "network" : profile.name) + ".toml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(TOMLCodec.render(profile, secret: secret).utf8).write(to: url, options: .atomic)
            validationMessage = "已导出 \(url.lastPathComponent)。"
        } catch {
            errors = ["无法导出：\(error.localizedDescription)"]
        }
    }

    // MARK: - Parsing helpers

    /// 把 listener 中非本机的绑定地址改为 0.0.0.0，保留协议/端口/路径。
    private func normalizeListenerHosts() {
        listenerText = lines(listenerText).map { line in
            guard let components = URLComponents(string: line),
                  let scheme = components.scheme,
                  let port = components.port else { return line }
            let path = components.path.isEmpty ? "" : components.path
            return "\(scheme)://0.0.0.0:\(port)\(path)"
        }.joined(separator: "\n")
        errors.removeAll { $0.contains("不属于本机") }
        validationMessage = "监听地址已改为 0.0.0.0，保存后生效。"
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseProxyNetworks(_ text: String) -> [ProxyNetwork] {
        lines(text).map { line in
            let parts = line.components(separatedBy: "->")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return ProxyNetwork(
                cidr: parts.first ?? "",
                mappedCIDR: parts.count > 1 ? parts[1] : ""
            )
        }
    }

    private func parsePortForwards(_ text: String) -> [PortForwardRule] {
        lines(text).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3 else { return nil }
            return PortForwardRule(proto: parts[0], bindAddress: parts[1], destination: parts[2])
        }
    }
}
