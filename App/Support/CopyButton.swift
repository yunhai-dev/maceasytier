import SwiftUI

/// 复制按钮：照搬 demo CopyButton 的交互（复制后短暂显示对勾）。
struct CopyButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let text: () -> String

    @State private var copied = false

    init(_ title: LocalizedStringKey, systemImage: String = "doc.on.doc", text: @escaping () -> String) {
        self.title = title
        self.systemImage = systemImage
        self.text = text
    }

    var body: some View {
        Button(title, systemImage: copied ? "checkmark" : systemImage, action: copy)
            .contentTransition(.symbolEffect(.replace))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
