import Foundation

/// 额度严重程度（来自 `limits[].severity`）；未知值 / 缺失为 `.unknown`，此时按百分比判断。
public enum UsageSeverity: String, Equatable {
    case normal, warning, critical, unknown
}

/// 显示用的级别：决定进度条颜色。
public enum UsageLevel: Equatable {
    case normal, warning, critical
}

/// 一项 Claude 额度（如 5 小时会话额度、7 天全部 / 某模型额度）。
public struct UsageLimit: Equatable, Identifiable {
    public let kind: String
    public let group: String?
    /// 已用百分比，0–100。
    public let percent: Double
    public let severity: UsageSeverity
    public let resetsAt: Date?
    /// `scope.model.display_name` 或 `scope.surface`。
    public let scopeLabel: String?
    /// 是否为当前起限制作用的额度。
    public let isActive: Bool

    public init(kind: String, group: String?, percent: Double, severity: UsageSeverity, resetsAt: Date?,
                scopeLabel: String?, isActive: Bool) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scopeLabel = scopeLabel
        self.isActive = isActive
    }

    /// kind + scope，用于区分同 kind 不同模型的额度（通知去重的键）。
    public var id: String { scopeLabel.map { "\(kind)|\($0)" } ?? kind }

    public var isSession: Bool { kind == "session" || group == "session" }
    public var isWeekly: Bool { kind.hasPrefix("weekly") || group == "weekly" }

    /// 完整名称：「5 小时」「7 天（全部）」「7 天 · Fable」；未知 kind 用原值。
    public var label: String {
        switch kind {
        case "session": return L("usage.limit.session")
        case "weekly_all": return L("usage.limit.weeklyAll")
        case "weekly_scoped": return scopeLabel.map { L("usage.limit.weeklyScoped", $0) } ?? L("usage.limit.weekly")
        default: return scopeLabel.map { "\(kind) · \($0)" } ?? kind
        }
    }

    /// 侧栏底部的短名称。
    public var shortLabel: String {
        if isSession { return "5h" }
        if isWeekly { return "7d" }
        return kind
    }

    /// 颜色级别：有 severity 时以它为准，否则 ≥90 critical、≥70 warning。
    public var level: UsageLevel {
        switch severity {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return percent >= 90 ? .critical : (percent >= 70 ? .warning : .normal)
        }
    }

    /// 缓存里的重置时间已过：这项数据已不代表当前周期。
    public func isExpired(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// Claude Code 缓存在 `~/.claude.json` 里的套餐与用量（只读）。
public struct ClaudeUsage: Equatable {
    public let planLabel: String
    public let limits: [UsageLimit]
    public let fetchedAt: Date
    /// `oauthAccount.hasExtraUsageEnabled`。
    public let extraUsageEnabled: Bool
    /// `cachedExtraUsageDisabledReason`（或 `extra_usage.disabled_reason`），如 "org_level_disabled_until"。
    public let extraUsageDisabledReason: String?

    public init(planLabel: String, limits: [UsageLimit], fetchedAt: Date, extraUsageEnabled: Bool,
                extraUsageDisabledReason: String?) {
        self.planLabel = planLabel
        self.limits = limits
        self.fetchedAt = fetchedAt
        self.extraUsageEnabled = extraUsageEnabled
        self.extraUsageDisabledReason = extraUsageDisabledReason
    }

    public var extraUsageText: String {
        guard extraUsageEnabled else { return L("usage.extra.off") }
        guard let reason = extraUsageDisabledReason else { return L("usage.extra.on") }
        return reason.hasPrefix("org_level_disabled") ? L("usage.extra.offByOrg") : L("usage.extra.offReason", reason)
    }

    /// 侧栏底部显示的额度：会话额度 + 百分比最高的周额度（并列时取当前限制的那个）。
    public var footerLimits: [UsageLimit] {
        var result: [UsageLimit] = []
        if let session = limits.first(where: \.isSession) { result.append(session) }
        let weekly = limits.filter { $0.isWeekly && !$0.isSession }
        if let top = weekly.max(by: { a, b in
            a.percent != b.percent ? a.percent < b.percent : (!a.isActive && b.isActive)
        }) {
            result.append(top)
        }
        return result
    }

    // MARK: 解析

    public static func parse(_ data: Data) -> ClaudeUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any] else { return nil }
        var limits = (utilization["limits"] as? [Any]).map(parseLimits) ?? []
        if limits.isEmpty { limits = parseNamedWindows(utilization) }
        guard !limits.isEmpty else { return nil }

        let account = root["oauthAccount"] as? [String: Any]
        let fetchedAt = number(cached["fetchedAtMs"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date.distantPast
        let extra = utilization["extra_usage"] as? [String: Any]
        let reason = nonEmpty(root["cachedExtraUsageDisabledReason"]) ?? nonEmpty(extra?["disabled_reason"])
        return ClaudeUsage(
            planLabel: planLabel(organizationType: nonEmpty(account?["organizationType"]),
                                 rateLimitTier: nonEmpty(account?["userRateLimitTier"])),
            limits: limits,
            fetchedAt: fetchedAt,
            extraUsageEnabled: (account?["hasExtraUsageEnabled"] as? Bool) ?? false,
            extraUsageDisabledReason: reason)
    }

    private static func parseLimits(_ items: [Any]) -> [UsageLimit] {
        items.compactMap { item in
            guard let dict = item as? [String: Any], let kind = nonEmpty(dict["kind"]),
                  let percent = number(dict["percent"]) else { return nil }
            let scope = dict["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let scopeLabel = nonEmpty(model?["display_name"]) ?? nonEmpty(scope?["surface"])
            return UsageLimit(kind: kind, group: nonEmpty(dict["group"]), percent: percent,
                              severity: nonEmpty(dict["severity"]).flatMap(UsageSeverity.init(rawValue:)) ?? .unknown,
                              resetsAt: nonEmpty(dict["resets_at"]).flatMap(parseDate),
                              scopeLabel: scopeLabel, isActive: (dict["is_active"] as? Bool) ?? false)
        }
    }

    /// 旧格式：five_hour / seven_day / seven_day_opus / seven_day_sonnet。
    private static func parseNamedWindows(_ utilization: [String: Any]) -> [UsageLimit] {
        let named: [(key: String, kind: String, group: String, scope: String?)] = [
            ("five_hour", "session", "session", nil),
            ("seven_day", "weekly_all", "weekly", nil),
            ("seven_day_opus", "weekly_scoped", "weekly", "Opus"),
            ("seven_day_sonnet", "weekly_scoped", "weekly", "Sonnet"),
        ]
        return named.compactMap { entry in
            guard let dict = utilization[entry.key] as? [String: Any],
                  let percent = number(dict["utilization"]) else { return nil }
            return UsageLimit(kind: entry.kind, group: entry.group, percent: percent, severity: .unknown,
                              resetsAt: nonEmpty(dict["resets_at"]).flatMap(parseDate),
                              scopeLabel: entry.scope, isActive: false)
        }
    }

    public static func planLabel(organizationType: String?, rateLimitTier: String?) -> String {
        let base: String
        switch organizationType {
        case "claude_team"?: base = "Team"
        case "claude_max"?: base = "Max"
        case "claude_pro"?: base = "Pro"
        case "enterprise"?, "claude_enterprise"?: base = "Enterprise"
        case let other?: base = other
        case nil: base = ""
        }
        let tier: String?
        if rateLimitTier?.contains("max_20x") == true {
            tier = "Max 20x"
        } else if rateLimitTier?.contains("max_5x") == true {
            tier = "Max 5x"
        } else {
            tier = nil
        }
        guard let tier else { return base }
        return base.isEmpty ? tier : "\(base) · \(tier)"
    }

    /// ISO 8601，可带任意位数小数秒与时区偏移（"2026-10-03T05:30:00.245924+00:00"）。
    public static func parseDate(_ string: String) -> Date? {
        guard let tIndex = string.firstIndex(of: "T") else { return nil }
        var base = string
        var fraction = 0.0
        if let dot = string[tIndex...].firstIndex(of: ".") {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { return nil }
            fraction = Double("0." + digits) ?? 0
            base = String(string[..<dot]) + String(afterDot.dropFirst(digits.count))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: base).map { $0.addingTimeInterval(fraction) }
    }

    /// 数字（Int / Double）；布尔与字符串不算。来自服务端 / 缓存文件，不可信：非有限值或超出 ±1e15 时 nil
    /// （之后会 `Int(percent.rounded())`，不能因为一个离谱的数崩溃）。
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && abs(d) < 1e15 ? d : nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// 重置时间的中文相对描述。
public enum UsageResetText {
    public static func text(resetsAt: Date, now: Date, calendar: Calendar) -> String {
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 { return L("reset.done") }
        if delta < 60 { return L("reset.soon") }
        if delta < 3600 { return L("reset.inMinutes", Int(delta / 60)) }
        if delta < 6 * 3600 { return L("reset.inHours", Int(delta / 3600)) }
        // 服务端常给 xx:59:59.6 这样的时间，按最近的整分钟显示。
        let resetsAt = Date(timeIntervalSince1970: (resetsAt.timeIntervalSince1970 / 60).rounded() * 60)
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: resetsAt),
                          calendar.component(.minute, from: resetsAt))
        if calendar.isDate(resetsAt, inSameDayAs: now) { return L("reset.today", time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(resetsAt, inSameDayAs: tomorrow) {
            return L("reset.tomorrow", time)
        }
        return L("reset.date", calendar.component(.month, from: resetsAt), calendar.component(.day, from: resetsAt))
    }
}

extension UsageLimit {
    /// 「89%」；缓存里的重置时间已过时为「—」（数据不代表当前周期）。
    public func percentText(now: Date) -> String {
        isExpired(now: now) ? "—" : "\(Int(percent.rounded()))%"
    }

    public func resetText(now: Date, calendar: Calendar) -> String? {
        resetsAt.map { UsageResetText.text(resetsAt: $0, now: now, calendar: calendar) }
    }
}

extension ClaudeUsage {
    /// 缓存超过这个时长视为可能过时。
    public static let staleAfter: TimeInterval = 30 * 60

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(fetchedAt) > Self.staleAfter }

    /// 「数据更新于 N 分钟前（来自 Claude Code 缓存）」。
    public func ageText(now: Date) -> String {
        let age = now.timeIntervalSince(fetchedAt)
        let when: String
        if fetchedAt == .distantPast {
            when = L("usage.age.unknown")
        } else if age < 60 {
            when = L("usage.age.now")
        } else if age < 3600 {
            when = L("usage.age.minutes", Int(age / 60))
        } else if age < 86400 {
            when = L("usage.age.hours", Int(age / 3600))
        } else {
            when = L("usage.age.days", Int(age / 86400))
        }
        return L("usage.age.format", when)
    }

    /// 悬停提示的多行文本。
    public func summary(now: Date, calendar: Calendar) -> String {
        var lines = [planLabel.isEmpty ? "Claude" : "Claude \(planLabel)"]
        for limit in limits {
            var line = "\(limit.label)  \(limit.percentText(now: now))"
            if let reset = limit.resetText(now: now, calendar: calendar) { line += "  \(reset)" }
            if limit.isActive { line += L("usage.activeLimitSuffix") }
            lines.append(line)
        }
        lines.append(L("usage.extraLine", extraUsageText))
        lines.append(ageText(now: now))
        return lines.joined(separator: "\n")
    }
}

/// 一条待发送的用量提醒。
public struct UsageAlert: Equatable {
    public let limitID: String
    /// 本周期的标识（重置时间取整到分钟），记录下来以免同一周期重复提醒。
    public let periodKey: Double
    public let title: String
    public let body: String
}

public enum UsageAlerts {
    public static let threshold = 90.0

    /// 对每项额度：≥90% 或 severity 为 critical、重置时间未过、且本周期未提醒过时产生一条提醒。
    /// `lastNotified`：limit id -> 上次提醒时的 periodKey。
    public static func pending(usage: ClaudeUsage, lastNotified: [String: Double], now: Date,
                               calendar: Calendar) -> [UsageAlert] {
        usage.limits.compactMap { limit in
            guard limit.percent >= threshold || limit.severity == .critical,
                  let resetsAt = limit.resetsAt, resetsAt > now else { return nil }
            let key = periodKey(resetsAt)
            guard lastNotified[limit.id] != key else { return nil }
            let reset = UsageResetText.text(resetsAt: resetsAt, now: now, calendar: calendar)
            return UsageAlert(limitID: limit.id, periodKey: key, title: L("usage.alert.title"),
                              body: L("usage.alert.body", limit.label, Int(limit.percent.rounded()), reset))
        }
    }

    static func periodKey(_ date: Date) -> Double {
        (date.timeIntervalSince1970 / 60).rounded() * 60
    }
}

/// 读取 `~/.claude.json`（只读）；文件 mtime 未变时直接返回上次结果。非线程安全，只在一个队列上使用。
public final class ClaudeUsageSource {
    public let path: String
    private var lastModified: Date?
    private var cached: ClaudeUsage?
    /// 实际解析次数（测试用）。
    public private(set) var parseCount = 0

    public init(path: String = NSHomeDirectory() + "/.claude.json") {
        self.path = path
    }

    public func read() -> ClaudeUsage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else {
            lastModified = nil
            cached = nil
            return nil
        }
        if modified == lastModified { return cached }
        lastModified = modified
        parseCount += 1
        cached = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(ClaudeUsage.parse)
        return cached
    }
}
