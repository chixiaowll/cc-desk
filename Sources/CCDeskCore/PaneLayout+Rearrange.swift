import Foundation
import CoreGraphics

/// 用鼠标整理窗格（设计 §20.2）：拖分隔线调整比例、拖标题条把窗格挪到另一个窗格旁边或互换。
/// 都是纯函数，界面只负责把鼠标位置换算进来。
extension PaneLayout {
    /// 把已显示的窗格 `id` 挪到 `target` 的 `edge` 一侧：先从原位置移走（父分割收拢），再分 `target`。
    /// 焦点跟到 `id`。两者相同或有一个不在布局里时返回 false，布局不变。
    @discardableResult
    public mutating func move(_ id: UUID, beside target: UUID, edge: PaneEdge) -> Bool {
        guard id != target, contains(id), contains(target) else { return false }
        return split(target, edge: edge, with: id)
    }

    /// 在 `size` 下能否把 `id` 挪到 `target` 的 `edge` 一侧：按移走 `id` 之后的布局判断 `target` 还分不分得开
    /// （两半都不小于 `minPane`）。尺寸未知（为 0）时只检查两者都在布局里。
    public func canMove(_ id: UUID, beside target: UUID, edge: PaneEdge, in size: CGSize, minPane: CGSize) -> Bool {
        guard id != target, contains(id), contains(target) else { return false }
        guard size.width > 0, size.height > 0 else { return true }
        var copy = self
        copy.remove(id)
        return copy.canSplit(target, edge: edge, in: size, minPane: minPane)
    }

    /// 拖动分隔线：按拖动开始时的分隔线位置加上位移 `delta`（横向分割为 x 方向，纵向为 y 方向）换算比例，
    /// 再限制在 `ratioRange`（两侧都不小于各自子树的最小尺寸）内。
    public func ratio(dragging divider: PaneDivider, by delta: CGFloat, in size: CGSize, minPane: CGSize) -> Double {
        let range = ratioRange(at: divider.path, in: size, minPane: minPane)
        let horizontal = divider.axis == .horizontal
        let extent = horizontal ? divider.rect.width : divider.rect.height
        let origin = horizontal ? divider.rect.minX : divider.rect.minY
        guard extent > 0, delta.isFinite else { return range.lowerBound }
        let proposed = Double((divider.position + delta - origin) / extent)
        return min(max(proposed, range.lowerBound), range.upperBound)
    }

    /// `point` 落在哪条分隔线的可拖动范围里（分隔线两侧各 `grab`）；有多条时取离得最近的。不考虑放大。
    public func divider(at point: CGPoint, in rect: CGRect, grab: CGFloat) -> PaneDivider? {
        PaneDivider.hit(point, among: dividers(in: rect), grab: grab)
    }
}

extension PaneDivider {
    /// 可拖动的范围：分隔线两侧各 `grab`，沿分隔线方向与所属分割的区域一样长。
    public func hitRect(grab: CGFloat) -> CGRect {
        axis == .horizontal
            ? CGRect(x: position - grab, y: rect.minY, width: grab * 2, height: rect.height)
            : CGRect(x: rect.minX, y: position - grab, width: rect.width, height: grab * 2)
    }

    /// `point` 落在哪条分隔线的可拖动范围里；有多条（T 形交点）时取离得最近的。
    public static func hit(_ point: CGPoint, among dividers: [PaneDivider], grab: CGFloat) -> PaneDivider? {
        var best: (divider: PaneDivider, distance: CGFloat)?
        for divider in dividers where divider.hitRect(grab: grab).contains(point) {
            let distance = abs((divider.axis == .horizontal ? point.x : point.y) - divider.position)
            if best.map({ distance < $0.distance }) ?? true { best = (divider, distance) }
        }
        return best?.divider
    }
}
