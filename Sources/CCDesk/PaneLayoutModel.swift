import AppKit
import Combine
import CCDeskCore

/// 主窗口详情区的分屏状态（设计 §20）。单独的对象：拖动分隔线时只有窗格区域重绘，不牵动整个 AppModel。
/// 布局本身是 Core 的 `PaneLayout`（纯数据）；这里只多了界面上的临时状态。只在主线程使用。
final class PaneLayoutModel: ObservableObject {
    @Published var layout = PaneLayout()
    /// ⌘D / ⇧⌘D 打开的「选择分屏内容」面板；nil 时不显示。
    @Published var picker: PaneSplitRequest?
    /// 从选择面板点了「新建会话…」：表单里新建的会话放进这个分屏（表单关闭时清掉）。
    var pendingSplit: PaneSplitRequest?
    /// 窗格区域最近一次的尺寸（判断还能不能再分、分隔线能拖到哪里）；未知时为 .zero。
    var areaSize: CGSize = .zero

    /// 每个窗格的最小尺寸（含标题条）。
    static let minPane = CGSize(width: 280, height: 160)

    /// 在 `target` 的 `edge` 一侧还能不能分出窗格（未满 4 个，且尺寸已知时两半都不小于最小尺寸）。
    func canSplit(_ target: UUID, edge: PaneEdge) -> Bool {
        guard layout.contains(target), !layout.isFull else { return false }
        guard areaSize.width > 0, areaSize.height > 0 else { return true }
        return layout.canSplit(target, edge: edge, in: areaSize, minPane: Self.minPane)
    }
}

/// 在某个窗格旁边分屏的请求：目标窗格（终端 id）与新窗格所在的一侧。
struct PaneSplitRequest: Equatable {
    let target: UUID
    let edge: PaneEdge
}
