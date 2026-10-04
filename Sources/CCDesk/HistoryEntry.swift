import Foundation
import CCDeskCore

/// 历史会话 + 其所属项目（用于按目录筛选与显示目录标签）。
struct HistoryEntry: Identifiable, Equatable {
    let item: HistoryItem
    let root: String
    let projectTitle: String
    var id: String { item.id }

    static func projectTitle(root: String) -> String {
        if root == NSHomeDirectory() { return "~" }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return name.isEmpty ? root : name
    }
}
