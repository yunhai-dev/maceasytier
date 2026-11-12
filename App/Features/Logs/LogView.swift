import AppKit
import SwiftUI

/// 日志窗口：按网络查看 easytier-core 的实时输出。
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var profileID: UUID?
    @State private var filter = ""
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logContent
        }
        .frame(minWidth: 520, minHeight: 300)
        .searchable(text: $filter, prompt: "过滤")
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

            Text("\(filteredLines.count) 行")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("跟随", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var logContent: some View {
        if let profileID, !filteredLines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filteredLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(10)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: filteredLines.count) { _, _ in
                    guard follow else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    CopyButton("复制") { filteredLines.joined(separator: "\n") }
                    Button("清空", systemImage: "trash") { model.core.clearLogs(id: profileID) }
                    Button("打开日志", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logFile(for: profileID)])
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "暂无日志",
                systemImage: "text.alignleft",
                description: Text(model.store.profiles.isEmpty ? "创建并启动网络后查看日志。" : "启动所选网络后查看日志。")
            )
        }
    }

    private var filteredLines: [String] {
        guard let profileID else { return [] }
        let lines = model.core.logs[profileID] ?? []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func selectDefaultProfile() {
        if let profileID, model.store.profile(id: profileID) != nil { return }
        profileID = model.store.profiles.first(where: { model.core.isRunning($0.id) })?.id
            ?? model.store.profiles.first?.id
    }
}
