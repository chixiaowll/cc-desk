import Foundation
import CoreGraphics

/// 分割方向：horizontal = 左右并排（竖直分隔线），vertical = 上下排列（水平分隔线）。
public enum PaneAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// 方位：分屏时新窗格放在哪一边；移动焦点时朝哪个方向。
public enum PaneEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom

    public var axis: PaneAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// 新窗格是否放在前面（左 / 上）。
    var isLeading: Bool { self == .left || self == .top }
}

/// 分割树的一个节点：叶子是一个终端（内嵌会话的 terminalID），内部节点是一次分割。
public indirect enum PaneNode: Equatable, Sendable {
    case leaf(UUID)
    case split(PaneSplit)

    /// 从左到右、从上到下的叶子顺序。
    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(let split): return split.first.leaves + split.second.leaves
        }
    }
}

public struct PaneSplit: Equatable, Sendable {
    public var axis: PaneAxis
    /// 第一个子节点（左 / 上）所占比例，0…1。
    public var ratio: Double
    public var first: PaneNode
    public var second: PaneNode

    public init(axis: PaneAxis, ratio: Double = 0.5, first: PaneNode, second: PaneNode) {
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

/// 树中内部节点的位置：从根开始，0 = 第一个子节点，1 = 第二个。
public typealias PanePath = [Int]

/// 一条分隔线：所属分割的路径、方向、分割的整个区域与分隔线所在的坐标（横向分割为 x，纵向为 y）。
public struct PaneDivider: Equatable, Sendable {
    public let path: PanePath
    public let axis: PaneAxis
    public let rect: CGRect
    public let position: CGFloat
}

/// 详情区的分屏布局（设计 §20）：纯数据，最多 4 个窗格，一个终端最多出现在一个窗格里。
/// 坐标约定与 SwiftUI 一致：原点在左上角，y 向下。
public struct PaneLayout: Equatable, Sendable {
    public static let maxPanes = 4
    /// 分割比例的硬限制（不知道实际尺寸时也不会把一边压没）。
    public static let ratioLimit = 0.1...0.9

    public private(set) var root: PaneNode?
    /// 当前焦点窗格（= 选中的会话）。
    public private(set) var focused: UUID?
    /// 放大显示的窗格（只显示它，其余窗格隐藏）；单窗格时为 nil。
    public private(set) var zoomed: UUID?

    public init(root: PaneNode? = nil, focused: UUID? = nil, zoomed: UUID? = nil) {
        self.root = root
        self.focused = focused
        self.zoomed = zoomed
        normalize()
    }

    public var leaves: [UUID] { root?.leaves ?? [] }
    public var count: Int { leaves.count }
    public var isEmpty: Bool { root == nil }
    /// 多于一个窗格（窗格显示标题条与焦点边框）。
    public var isSplit: Bool { count > 1 }
    public var isFull: Bool { count >= Self.maxPanes }

    public func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    // MARK: 修改

    /// 把焦点移到某个窗格；不在布局里时返回 false。
    @discardableResult
    public mutating func focus(_ id: UUID) -> Bool {
        guard contains(id) else { return false }
        focused = id
        if zoomed != nil, zoomed != id { zoomed = id }
        return true
    }

    /// 让终端显示出来：已在布局里则聚焦；布局为空则成为唯一窗格；否则替换焦点窗格（没有焦点时替换第一个）。
    public mutating func show(_ id: UUID) {
        if focus(id) { return }
        guard let target = focused ?? leaves.first else {
            root = .leaf(id)
            focused = id
            return
        }
        replace(target, with: id)
    }

    /// 在 `leaf` 的 `edge` 一侧分出新窗格放 `new`，焦点移到新窗格。`new` 已在别的窗格时先从那里移走。
    /// 已满 4 个、`leaf` 不在布局里或 `new == leaf` 时返回 false，布局不变。
    @discardableResult
    public mutating func split(_ leaf: UUID, edge: PaneEdge, with new: UUID) -> Bool {
        guard leaf != new, contains(leaf) else { return false }
        var copy = self
        if copy.contains(new) { copy.remove(new) }
        guard copy.count < Self.maxPanes, let root = copy.root,
              let updated = Self.splitting(root, leaf: leaf, edge: edge, new: new) else { return false }
        copy.root = updated
        copy.focused = new
        copy.zoomed = nil
        self = copy
        return true
    }

    /// 从布局里移除终端，父分割收拢为另一侧。被移除的是焦点时，焦点移到接替它位置的窗格。
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let root, contains(id) else { return false }
        let (updated, heir) = Self.removing(id, from: root)
        self.root = updated
        if focused == id { focused = heir ?? leaves.first }
        if zoomed == id || count < 2 { zoomed = nil }
        return true
    }

    /// 把 `leaf` 窗格换成 `new`。`new` 已在另一个窗格时两者互换位置。焦点跟到 `new`。
    @discardableResult
    public mutating func replace(_ leaf: UUID, with new: UUID) -> Bool {
        guard contains(leaf) else { return false }
        if leaf == new { return focus(new) }
        if contains(new) {
            swap(leaf, new)
        } else if let root {
            self.root = Self.mapLeaves(root) { $0 == leaf ? new : $0 }
            if zoomed == leaf { zoomed = new }
        }
        focused = new
        return true
    }

    /// 交换两个窗格的内容（焦点 / 放大跟着终端走）。
    @discardableResult
    public mutating func swap(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b, contains(a), contains(b), let root else { return false }
        self.root = Self.mapLeaves(root) { $0 == a ? b : ($0 == b ? a : $0) }
        return true
    }

    /// 设置某个分割的比例（限制在 `ratioLimit` 内）；路径不是分割时返回 false。
    @discardableResult
    public mutating func setRatio(_ ratio: Double, at path: PanePath) -> Bool {
        guard let root, ratio.isFinite, let updated = Self.updatingSplit(root, at: path[...], { split in
            split.ratio = min(max(ratio, Self.ratioLimit.lowerBound), Self.ratioLimit.upperBound)
        }) else { return false }
        self.root = updated
        return true
    }

    /// 放大 / 还原某个窗格（nil 为焦点窗格）；单窗格时不放大。
    public mutating func toggleZoom(_ id: UUID? = nil) {
        guard let target = id ?? focused, contains(target), isSplit else {
            zoomed = nil
            return
        }
        if zoomed == target {
            zoomed = nil
        } else {
            zoomed = target
            focused = target
        }
    }

    /// 朝某个方向移动焦点；那边没有窗格时返回 nil，焦点不变。放大时先还原。
    @discardableResult
    public mutating func moveFocus(_ edge: PaneEdge) -> UUID? {
        guard let current = focused, let target = neighbor(of: current, toward: edge) else { return nil }
        zoomed = nil
        focused = target
        return target
    }

    /// 整理：去掉不在 `valid` 里的终端（nil 不过滤）与重复的叶子，超过 4 个的丢掉，比例限制在范围内，
    /// 焦点 / 放大指向不存在的窗格时修正。
    public mutating func normalize(keeping valid: Set<UUID>? = nil) {
        var seen = Set<UUID>()
        root = root.flatMap { Self.pruned($0, valid: valid, seen: &seen) }
        if let focused, !contains(focused) { self.focused = nil }
        if focused == nil { focused = leaves.first }
        if let zoomed, !contains(zoomed) || count < 2 { self.zoomed = nil }
    }

    // MARK: 几何

    /// 各窗格在 `rect` 里的位置（不考虑放大）。
    public func frames(in rect: CGRect) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        guard let root else { return result }
        Self.walk(root, rect: rect, path: []) { node, rect, _ in
            if case .leaf(let id) = node { result[id] = rect }
        }
        return result
    }

    /// 所有分隔线（不考虑放大）。
    public func dividers(in rect: CGRect) -> [PaneDivider] {
        var result: [PaneDivider] = []
        guard let root else { return result }
        Self.walk(root, rect: rect, path: []) { node, rect, path in
            guard case .split(let split) = node else { return }
            let position = split.axis == .horizontal
                ? rect.minX + rect.width * CGFloat(split.ratio)
                : rect.minY + rect.height * CGFloat(split.ratio)
            result.append(PaneDivider(path: path, axis: split.axis, rect: rect, position: position))
        }
        return result
    }

    /// 某个分割在 `size` 下允许的比例范围：两侧都不小于各自子树的最小尺寸（每个窗格至少 `minPane`）。
    /// 放不下时返回当前比例附近的单点（不再变化）。
    public func ratioRange(at path: PanePath, in size: CGSize, minPane: CGSize) -> ClosedRange<Double> {
        let limit = Self.ratioLimit
        guard let divider = dividers(in: CGRect(origin: .zero, size: size)).first(where: { $0.path == path }),
              let root, case .split(let split)? = Self.node(root, at: path[...]) else { return limit }
        let horizontal = split.axis == .horizontal
        let extent = Double(horizontal ? divider.rect.width : divider.rect.height)
        guard extent > 0 else { return limit }
        let a = Self.minSize(split.first, minPane: minPane), b = Self.minSize(split.second, minPane: minPane)
        let lo = max(limit.lowerBound, Double(horizontal ? a.width : a.height) / extent)
        let hi = min(limit.upperBound, 1 - Double(horizontal ? b.width : b.height) / extent)
        if lo <= hi { return lo...hi }
        let middle = min(max((lo + hi) / 2, limit.lowerBound), limit.upperBound)
        return middle...middle
    }

    /// 在 `size` 下能否在 `leaf` 的 `edge` 一侧再分出一个窗格（两半都不小于 `minPane`，且未满 4 个）。
    public func canSplit(_ leaf: UUID, edge: PaneEdge, in size: CGSize, minPane: CGSize) -> Bool {
        guard !isFull, let frame = frames(in: CGRect(origin: .zero, size: size))[leaf] else { return false }
        return edge.axis == .horizontal ? frame.width >= minPane.width * 2 : frame.height >= minPane.height * 2
    }

    /// 某个窗格在 `edge` 方向上相邻的窗格：在那一侧、与它在另一个方向上有重叠，取最近的；
    /// 同样近时取重叠最多的，再取靠左 / 靠上的。
    public func neighbor(of id: UUID, toward edge: PaneEdge) -> UUID? {
        let frames = self.frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let origin = frames[id] else { return nil }
        let epsilon: CGFloat = 1e-6
        var best: (id: UUID, distance: CGFloat, overlap: CGFloat, order: CGFloat)?
        for leaf in leaves where leaf != id {
            guard let frame = frames[leaf] else { continue }
            let distance: CGFloat
            let overlap: CGFloat
            switch edge {
            case .left: distance = origin.minX - frame.maxX
            case .right: distance = frame.minX - origin.maxX
            case .top: distance = origin.minY - frame.maxY
            case .bottom: distance = frame.minY - origin.maxY
            }
            if edge.axis == .horizontal {
                overlap = min(origin.maxY, frame.maxY) - max(origin.minY, frame.minY)
            } else {
                overlap = min(origin.maxX, frame.maxX) - max(origin.minX, frame.minX)
            }
            guard distance > -epsilon, overlap > epsilon else { continue }
            let order = edge.axis == .horizontal ? frame.minY : frame.minX
            if let current = best {
                if distance > current.distance + epsilon { continue }
                if abs(distance - current.distance) <= epsilon {
                    if overlap < current.overlap - epsilon { continue }
                    if abs(overlap - current.overlap) <= epsilon, order >= current.order { continue }
                }
            }
            best = (leaf, distance, overlap, order)
        }
        return best?.id
    }

    // MARK: 树操作（私有）

    private static func splitting(_ node: PaneNode, leaf: UUID, edge: PaneEdge, new: UUID) -> PaneNode? {
        switch node {
        case .leaf(let id):
            guard id == leaf else { return nil }
            let created = PaneNode.leaf(new)
            return .split(PaneSplit(axis: edge.axis, ratio: 0.5,
                                    first: edge.isLeading ? created : node,
                                    second: edge.isLeading ? node : created))
        case .split(var split):
            if let first = splitting(split.first, leaf: leaf, edge: edge, new: new) {
                split.first = first
            } else if let second = splitting(split.second, leaf: leaf, edge: edge, new: new) {
                split.second = second
            } else {
                return nil
            }
            return .split(split)
        }
    }

    /// 返回移除后的子树与接替被移除叶子位置的叶子（兄弟子树里离它最近的那个）。
    private static func removing(_ id: UUID, from node: PaneNode) -> (PaneNode?, UUID?) {
        switch node {
        case .leaf(let leaf):
            return leaf == id ? (nil, nil) : (node, nil)
        case .split(var split):
            if split.first.leaves.contains(id) {
                let (first, heir) = removing(id, from: split.first)
                guard let first else { return (split.second, split.second.leaves.first) }
                split.first = first
                return (.split(split), heir)
            }
            let (second, heir) = removing(id, from: split.second)
            guard let second else { return (split.first, split.first.leaves.last) }
            split.second = second
            return (.split(split), heir)
        }
    }

    private static func mapLeaves(_ node: PaneNode, _ transform: (UUID) -> UUID) -> PaneNode {
        switch node {
        case .leaf(let id): return .leaf(transform(id))
        case .split(var split):
            split.first = mapLeaves(split.first, transform)
            split.second = mapLeaves(split.second, transform)
            return .split(split)
        }
    }

    private static func node(_ node: PaneNode, at path: ArraySlice<Int>) -> PaneNode? {
        guard let step = path.first else { return node }
        guard case .split(let split) = node, step == 0 || step == 1 else { return nil }
        return Self.node(step == 0 ? split.first : split.second, at: path.dropFirst())
    }

    private static func updatingSplit(_ node: PaneNode, at path: ArraySlice<Int>,
                                      _ update: (inout PaneSplit) -> Void) -> PaneNode? {
        guard case .split(var split) = node else { return nil }
        guard let step = path.first else {
            update(&split)
            return .split(split)
        }
        switch step {
        case 0:
            guard let first = updatingSplit(split.first, at: path.dropFirst(), update) else { return nil }
            split.first = first
        case 1:
            guard let second = updatingSplit(split.second, at: path.dropFirst(), update) else { return nil }
            split.second = second
        default:
            return nil
        }
        return .split(split)
    }

    private static func pruned(_ node: PaneNode, valid: Set<UUID>?, seen: inout Set<UUID>) -> PaneNode? {
        switch node {
        case .leaf(let id):
            guard valid?.contains(id) ?? true, seen.count < maxPanes, seen.insert(id).inserted else { return nil }
            return node
        case .split(var split):
            let first = pruned(split.first, valid: valid, seen: &seen)
            let second = pruned(split.second, valid: valid, seen: &seen)
            guard let first else { return second }
            guard let second else { return first }
            split.first = first
            split.second = second
            split.ratio = split.ratio.isFinite
                ? min(max(split.ratio, ratioLimit.lowerBound), ratioLimit.upperBound) : 0.5
            return .split(split)
        }
    }

    private static func walk(_ node: PaneNode, rect: CGRect, path: PanePath,
                             _ visit: (PaneNode, CGRect, PanePath) -> Void) {
        visit(node, rect, path)
        guard case .split(let split) = node else { return }
        let ratio = CGFloat(split.ratio)
        let a: CGRect, b: CGRect
        if split.axis == .horizontal {
            let width = rect.width * ratio
            a = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            b = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        } else {
            let height = rect.height * ratio
            a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            b = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
        }
        walk(split.first, rect: a, path: path + [0], visit)
        walk(split.second, rect: b, path: path + [1], visit)
    }

    /// 子树的最小尺寸：左右并排时宽度相加、高度取大；上下排列时反之。
    private static func minSize(_ node: PaneNode, minPane: CGSize) -> CGSize {
        switch node {
        case .leaf: return minPane
        case .split(let split):
            let a = minSize(split.first, minPane: minPane), b = minSize(split.second, minPane: minPane)
            return split.axis == .horizontal
                ? CGSize(width: a.width + b.width, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + b.height)
        }
    }
}

// MARK: Codable

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey { case leaf, axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .leaf) {
            self = .leaf(id)
            return
        }
        self = .split(PaneSplit(axis: try c.decode(PaneAxis.self, forKey: .axis),
                                ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
                                first: try c.decode(PaneNode.self, forKey: .first),
                                second: try c.decode(PaneNode.self, forKey: .second)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let id):
            try c.encode(id, forKey: .leaf)
        case .split(let split):
            try c.encode(split.axis, forKey: .axis)
            try c.encode(split.ratio, forKey: .ratio)
            try c.encode(split.first, forKey: .first)
            try c.encode(split.second, forKey: .second)
        }
    }
}

extension PaneLayout: Codable {
    private enum CodingKeys: String, CodingKey { case root, focused, zoomed }

    /// 解码后整理（去重、限制数量与比例）；树结构损坏时得到空布局，不让整份 workspace 解码失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(root: (try? c.decodeIfPresent(PaneNode.self, forKey: .root)) ?? nil,
                  focused: (try? c.decodeIfPresent(UUID.self, forKey: .focused)) ?? nil,
                  zoomed: (try? c.decodeIfPresent(UUID.self, forKey: .zoomed)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(root, forKey: .root)
        try c.encodeIfPresent(focused, forKey: .focused)
        try c.encodeIfPresent(zoomed, forKey: .zoomed)
    }
}
