import Foundation
import CoreGraphics

/// 把会话拖到窗格上时的落点：四边分屏，中间替换。
public enum PaneDropZone: Equatable, Sendable {
    case edge(PaneEdge)
    case center

    /// 按落点在窗格里的相对位置判断：离中心较近（归一化后都在 0.4 以内）为替换，否则取更靠近的那条边。
    public static func at(_ point: CGPoint, in rect: CGRect) -> PaneDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let dx = (point.x - rect.midX) / (rect.width / 2)
        let dy = (point.y - rect.midY) / (rect.height / 2)
        if abs(dx) < 0.4, abs(dy) < 0.4 { return .center }
        if abs(dx) >= abs(dy) { return .edge(dx < 0 ? .left : .right) }
        return .edge(dy < 0 ? .top : .bottom)
    }

    /// 高亮区域：边为对应的半个窗格，中间为整个窗格。坐标原点在左上角。
    public func highlight(in rect: CGRect) -> CGRect {
        switch self {
        case .center: return rect
        case .edge(.left): return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .edge(.right): return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .edge(.top): return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .edge(.bottom): return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}
