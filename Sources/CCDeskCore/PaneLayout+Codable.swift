import Foundation

/// 分屏布局的 JSON 形式（存在 workspace.json 的 `layout` 里，设计 §20.1）。
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
