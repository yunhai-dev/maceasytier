import SwiftUI

/// 兼容层：照搬 demo Compat.swift 的导航/窗口相关写法，
/// 保证低版本 macOS 也能编译，高版本走 glass 样式。
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(tint: Color? = nil, interactive _: Bool = false, in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular.tint(tint), in: shape)
        } else {
            self.background {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill((tint ?? .clear).opacity(0.12)) }
            }
        }
    }

    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glass) }
        else { self.buttonStyle(.bordered) }
    }

    @ViewBuilder
    func rotatingSymbol(isActive: Bool) -> some View {
        if #available(macOS 15, *) { self.symbolEffect(.rotate, isActive: isActive) }
        else { self }
    }
}

struct CompatGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing, content: content) }
        else { content() }
    }
}

struct CompatToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }
}

extension ToolbarItem {
    @ToolbarContentBuilder
    func compatHiddenBackground() -> some ToolbarContent {
        if #available(macOS 26, *) { self.sharedBackgroundVisibility(.hidden) }
        else { self }
    }
}

extension Scene {
    /// 照搬 demo 的 launchSuppressed：Logs / Rules / Connections 窗口默认不自动打开。
    func launchSuppressed(_ suppressed: Bool = true) -> some Scene {
        if #available(macOS 15, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                self.defaultLaunchBehavior(suppressed ? .suppressed : .presented)))
        }
        return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
    }
}
