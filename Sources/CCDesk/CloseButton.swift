import SwiftUI

/// 弹窗 / 面板右上角统一的关闭按钮（×）：不依赖键盘，鼠标点一下就关。悬停时加深并显示浅底。
struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("action.close"))
        .accessibilityLabel(L("action.close"))
    }
}
