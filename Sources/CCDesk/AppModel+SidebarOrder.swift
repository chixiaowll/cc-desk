import AppKit
import CCDeskCore

/// 侧栏顺序（右键菜单 / 拖拽）。
extension AppModel {
    func moveGroup(_ id: String, _ move: SidebarOrder.Move) {
        sidebarOrder.moveGroup(id, move, in: groups.map(\.id))
        orderChanged()
    }

    func moveRow(_ row: SidebarRow, _ move: SidebarOrder.Move) {
        guard let group = groups.first(where: { $0.rows.contains { $0.id == row.id } }) else { return }
        sidebarOrder.moveRow(row.id, move, in: group.rows)
        orderChanged()
    }

    /// 拖拽：payload 为 "group:<id>" 或 "row:<id>"；放到同类的目标上即占据目标的位置（会话只能在组内移动）。
    func dropForReorder(_ payload: String, ontoGroup groupID: String?, ontoRow rowID: String?) -> Bool {
        if payload.hasPrefix("group:"), let groupID {
            let id = String(payload.dropFirst("group:".count))
            let ids = groups.map(\.id)
            guard id != groupID, let index = ids.firstIndex(of: groupID) else { return false }
            sidebarOrder.moveGroup(id, to: index, in: ids)
        } else if payload.hasPrefix("row:"), let rowID {
            let id = String(payload.dropFirst("row:".count))
            guard id != rowID, let group = groups.first(where: { $0.rows.contains { $0.id == rowID } }),
                  group.rows.contains(where: { $0.id == id }),
                  let index = group.rows.firstIndex(where: { $0.id == rowID }) else { return false }
            sidebarOrder.moveRow(id, to: index, in: group.rows)
        } else {
            return false
        }
        orderChanged()
        return true
    }

    private func orderChanged() {
        rebuildGroups()
        let snapshot = sidebarOrder
        queue.async { snapshot.save() }
    }
}
