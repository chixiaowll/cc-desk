import Foundation

/// 侧栏上随时间变化的文字（会话行的「刚刚 / N 分钟 / N 小时…」与变灰、底部用量的百分比 / 重置时间 / 数据新旧）
/// 下一次会变的时刻（设计 §26.3）。侧栏时钟只在这些时刻（或内容本身变了时）前进，而不是每秒重绘一次。
public enum DisplayClock {
    /// 比边界多走一点，保证到点时用 `>` / `<=` 比较的文字确实已经变了。
    static let epsilon: TimeInterval = 0.001

    /// `RelativeTime.short(from: date, now:)` 或 `RelativeTime.isStale` 在 `now` 之后下一次变化的时刻；不再变化时 nil。
    public static func nextChange(relativeTo date: Date, after now: Date) -> Date? {
        guard date != .distantPast else { return nil }
        let elapsed = now.timeIntervalSince(date)
        // 将来的时间（时钟回拨）在显示上等同于 0 秒前。
        guard elapsed >= 0 else { return date.addingTimeInterval(60) }
        var next = date.addingTimeInterval(countUp(elapsed: elapsed, units: [60, 3600, 86400, 7 * 86400.0]))
        // 变灰（isStale）用的是严格大于 24 小时。
        if elapsed <= 86400 { next = min(next, date.addingTimeInterval(86400 + epsilon)) }
        return next
    }

    /// 用量（`ClaudeUsage`）在侧栏 / 弹出层上随时间变化的文字下一次变化的时刻。
    public static func nextChange(usage: ClaudeUsage, after now: Date, calendar: Calendar) -> Date? {
        var candidates: [Date] = []
        for limit in usage.limits {
            guard let resetsAt = limit.resetsAt else { continue }
            if let next = nextResetTextChange(resetsAt: resetsAt, after: now, calendar: calendar) { candidates.append(next) }
        }
        if usage.fetchedAt != .distantPast {
            let age = now.timeIntervalSince(usage.fetchedAt)
            if age < 0 {
                candidates.append(usage.fetchedAt.addingTimeInterval(60))
            } else {
                candidates.append(usage.fetchedAt.addingTimeInterval(countUp(elapsed: age, units: [60, 3600, 86400.0])))
                if age <= ClaudeUsage.staleAfter {
                    candidates.append(usage.fetchedAt.addingTimeInterval(ClaudeUsage.staleAfter + epsilon))
                }
            }
        }
        return candidates.min()
    }

    /// 一组会话时间与（可选的）用量里最早的下一次变化。
    public static func nextChange(dates: [Date], usage: ClaudeUsage?, after now: Date, calendar: Calendar) -> Date? {
        var next = dates.lazy.compactMap { nextChange(relativeTo: $0, after: now) }.min()
        if let usage, let u = nextChange(usage: usage, after: now, calendar: calendar) {
            next = next.map { min($0, u) } ?? u
        }
        return next
    }

    /// `UsageResetText.text` / `percentText`（到点变「—」）下一次变化的时刻；已经过了重置时间后不再变化。
    static func nextResetTextChange(resetsAt: Date, after now: Date, calendar: Calendar) -> Date? {
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 { return nil }
        if delta < 60 { return resetsAt }
        if delta < 6 * 3600 {
            // 「N 分钟后 / N 小时后」取整数部分：剩余时间降到下一个整单位以下时变化。
            let unit: TimeInterval = delta < 3600 ? 60 : 3600
            let whole = (delta / unit).rounded(.down) * unit
            return now.addingTimeInterval(delta - whole + epsilon)
        }
        // 6 小时以上显示「今天 / 明天 HH:mm / M 月 D 日」：跨过 6 小时或跨过午夜时变化。
        let sixHours = resetsAt.addingTimeInterval(-6 * 3600 + epsilon)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? sixHours
        return min(sixHours, midnight)
    }

    /// 已过去 `elapsed` 秒、显示为「floor(elapsed / 单位)」时，到下一个整单位还要多久（相对起点的秒数）。
    /// `units` 为各档的单位，档位上限等于下一档的单位（60 秒内都是「刚刚」，即单位 60 的第 0 格）。
    private static func countUp(elapsed: TimeInterval, units: [TimeInterval]) -> TimeInterval {
        var unit = units[0]
        for (i, u) in units.enumerated() {
            unit = u
            if i + 1 < units.count, elapsed < units[i + 1] { break }
        }
        return ((elapsed / unit).rounded(.down) + 1) * unit
    }
}
