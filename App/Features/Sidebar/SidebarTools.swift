import AppKit
import SwiftUI

/// 侧边栏底部工具栏：路由和设置的窗口入口。
struct SidebarTools: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        CompatGlassGroup(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                SidebarGlassButton(title: "路由", systemImage: "arrow.triangle.branch") {
                    openWindow(id: "routes")
                }
                SidebarGlassButton(title: "设置", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct SidebarGlassButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                if isHovering {
                    Text(title)
                        .fontWeight(.medium)
                        .fixedSize()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25), value: isHovering)
        .glassSurface(tint: isHovering ? Color.accentColor.opacity(0.25) : nil, in: .capsule)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) { isHovering = hovering }
        }
        .accessibilityLabel(title)
        .help(title)
    }
}
