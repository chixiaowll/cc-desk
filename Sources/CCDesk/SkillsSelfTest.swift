import Foundation
import CCDeskCore

/// `CCDesk --skills-selftest`：不启动界面，只读扫描本机的技能目录（设计 §21），打印各来源的数量与名字（不打印内容），
/// 并检查条目标识不重复。不写任何文件、不连接正在运行的 CC Desk。
enum SkillsSelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.dropFirst().contains("--skills-selftest") else { return }
        exit(run() ? 0 : 1)
    }

    static func run() -> Bool {
        setvbuf(stdout, nil, _IOLBF, 0)
        let started = Date()
        let entries = SkillScanner.scan(.standard())
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        var groups: [(label: String, names: [String])] = []
        for entry in entries {
            var label = entry.source.label
            if case .claudePlugin(_, _, let version, let enabled) = entry.source {
                label += (version.map { " v\($0)" } ?? "") + (enabled ? "" : " (disabled)")
            }
            if entry.kind != .skill { label += " [\(entry.kind.rawValue)]" }
            let name = entry.name + (entry.sources.count > 1 ? " (+\(entry.sources.dropFirst().map(\.label).joined(separator: ",")))" : "")
            if let i = groups.firstIndex(where: { $0.label == label }) {
                groups[i].names.append(name)
            } else {
                groups.append((label, [name]))
            }
        }
        for group in groups {
            print("\(group.label): \(group.names.count) — \(group.names.joined(separator: ", "))")
        }
        let unique = Set(entries.map(\.id)).count == entries.count
        let named = entries.allSatisfy { !$0.name.isEmpty }
        print("total \(entries.count) in \(elapsed) ms; unique ids: \(unique); all named: \(named)")
        return unique && named
    }
}
