import XCTest
@testable import CCDeskCore

final class ClaudeUsageTests: ZhHansTestCase {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    private let withLimits = """
    {
      "numStartups": 3,
      "cachedExtraUsageDisabledReason": "org_level_disabled_until",
      "oauthAccount": {
        "organizationType": "claude_team",
        "seatTier": "team_tier_1",
        "userRateLimitTier": "default_claude_max_5x",
        "hasExtraUsageEnabled": true,
        "billingType": "stripe_subscription"
      },
      "cachedUsageUtilization": {
        "fetchedAtMs": 1790000000000,
        "utilization": {
          "five_hour": {"utilization": 99, "resets_at": "2026-10-03T05:30:00+00:00"},
          "seven_day": {"utilization": 99, "resets_at": "2026-10-04T01:00:00+00:00"},
          "tangelo": null,
          "extra_usage": {"utilization": null},
          "limits": [
            {"kind": "session", "group": "session", "percent": 20, "severity": "normal",
             "resets_at": "2026-10-03T05:30:00.245924+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 89, "severity": "warning",
             "resets_at": "2026-10-04T00:59:59.606977+00:00", "scope": null, "is_active": true},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 86.5, "severity": "warning",
             "resets_at": "2026-10-04T00:59:59.607158+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false},
            {"kind": "monthly_thing", "group": "monthly", "percent": 5, "severity": "spicy",
             "resets_at": null, "scope": {"model": null, "surface": "Desktop"}, "is_active": false},
            {"kind": "broken", "percent": "x"},
            null
          ]
        }
      }
    }
    """

    func testHugePercentIsIgnoredNotCrashing() throws {
        let text = #"{"cachedUsageUtilization":{"fetchedAtMs":1790000000000,"utilization":{"limits":[{"kind":"session","percent":1e30},{"kind":"weekly_all","percent":42}]}}}"#
        let usage = try XCTUnwrap(ClaudeUsage.parse(json(text)))
        XCTAssertEqual(usage.limits.map(\.kind), ["weekly_all"])
        XCTAssertEqual(usage.limits.first?.percentText(now: Date(timeIntervalSince1970: 0)), "42%")
    }

    func testParsesLimitsArrayAsPrimarySource() throws {
        let usage = try XCTUnwrap(ClaudeUsage.parse(json(withLimits)))
        XCTAssertEqual(usage.planLabel, "Team · Max 5x")
        XCTAssertEqual(usage.fetchedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(usage.limits.map(\.kind), ["session", "weekly_all", "weekly_scoped", "monthly_thing"])
        let session = usage.limits[0]
        XCTAssertEqual(session.percent, 20)
        XCTAssertEqual(session.severity, .normal)
        XCTAssertNil(session.scopeLabel)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.label, "5 小时")
        XCTAssertEqual(session.shortLabel, "5h")
        let reset = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970,
                       (ClaudeUsage.parseDate("2026-10-03T05:30:00Z")?.timeIntervalSince1970 ?? 0) + 0.245924, accuracy: 0.001)

        let weekly = usage.limits[1]
        XCTAssertEqual(weekly.label, "7 天（全部）")
        XCTAssertEqual(weekly.shortLabel, "7d")
        XCTAssertEqual(weekly.severity, .warning)
        XCTAssertTrue(weekly.isActive)

        let scoped = usage.limits[2]
        XCTAssertEqual(scoped.shortLabel, "7d " + (scoped.scopeLabel ?? ""))
        XCTAssertEqual(scoped.scopeLabel, "Fable")
        XCTAssertEqual(scoped.label, "7 天 · Fable")
        XCTAssertEqual(scoped.percent, 86.5)
        XCTAssertNotEqual(scoped.id, weekly.id)

        let unknown = usage.limits[3]
        XCTAssertEqual(unknown.severity, .unknown)
        XCTAssertEqual(unknown.scopeLabel, "Desktop")
        XCTAssertEqual(unknown.label, "monthly_thing · Desktop")
        XCTAssertNil(unknown.resetsAt)
    }

    func testFallsBackToNamedWindowsWithoutLimits() throws {
        let s = """
        {"oauthAccount": {"organizationType": "claude_max", "userRateLimitTier": "default_claude_max_20x"},
         "cachedUsageUtilization": {"fetchedAtMs": 1790000000000.0, "utilization": {
           "five_hour": {"utilization": 3.25, "resets_at": "2026-10-03T05:30:00.1+00:00"},
           "seven_day": {"utilization": 40},
           "seven_day_opus": null,
           "seven_day_sonnet": {"utilization": 12, "resets_at": "garbage"},
           "seven_day_cowork": {"utilization": "x"}
         }}}
        """
        let usage = try XCTUnwrap(ClaudeUsage.parse(json(s)))
        XCTAssertEqual(usage.planLabel, "Max · Max 20x")
        XCTAssertEqual(usage.limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])
        XCTAssertEqual(usage.limits.map(\.label), ["5 小时", "7 天（全部）", "7 天 · Sonnet"])
        XCTAssertEqual(usage.limits[0].percent, 3.25)
        XCTAssertNotNil(usage.limits[0].resetsAt)
        XCTAssertNil(usage.limits[1].resetsAt)
        XCTAssertNil(usage.limits[2].resetsAt)
        XCTAssertTrue(usage.limits.allSatisfy { $0.severity == .unknown && !$0.isActive })
    }

    func testMissingBlockReturnsNil() {
        XCTAssertNil(ClaudeUsage.parse(json(#"{"oauthAccount": {"organizationType": "claude_max"}}"#)))
        XCTAssertNil(ClaudeUsage.parse(json(#"{"cachedUsageUtilization": null}"#)))
        XCTAssertNil(ClaudeUsage.parse(json("not json")))
        XCTAssertNil(ClaudeUsage.parse(json("[]")))
        let empty = #"{"cachedUsageUtilization": {"fetchedAtMs": 1, "utilization": {"five_hour": null, "limits": []}}}"#
        XCTAssertNil(ClaudeUsage.parse(json(empty)))
    }

    func testEmptyLimitsArrayFallsBackToWindows() throws {
        let s = """
        {"cachedUsageUtilization": {"fetchedAtMs": 1, "utilization": {
          "five_hour": {"utilization": 7, "resets_at": "2026-10-03T05:30:00+00:00"}, "limits": []}}}
        """
        XCTAssertEqual(try XCTUnwrap(ClaudeUsage.parse(json(s))).limits.map(\.kind), ["session"])
    }

    func testExtraUsageText() throws {
        let disabled = try XCTUnwrap(ClaudeUsage.parse(json(withLimits)))
        XCTAssertTrue(disabled.extraUsageEnabled)
        XCTAssertEqual(disabled.extraUsageDisabledReason, "org_level_disabled_until")
        XCTAssertEqual(disabled.extraUsageText, "未开启（组织已停用）")
        func usage(_ enabled: Bool, _ reason: String?) -> ClaudeUsage {
            ClaudeUsage(planLabel: "", limits: [], fetchedAt: Date(), extraUsageEnabled: enabled, extraUsageDisabledReason: reason)
        }
        XCTAssertEqual(usage(true, nil).extraUsageText, "已开启")
        XCTAssertEqual(usage(false, nil).extraUsageText, "未开启")
        XCTAssertEqual(usage(true, "out_of_credits").extraUsageText, "未开启（out_of_credits）")
    }

    func testFooterPicksSessionAndHighestWeekly() throws {
        let usage = try XCTUnwrap(ClaudeUsage.parse(json(withLimits)))
        XCTAssertEqual(usage.footerLimits.map(\.kind), ["session", "weekly_all"])
        func limit(_ kind: String, _ percent: Double, active: Bool = false, scope: String? = nil) -> UsageLimit {
            UsageLimit(kind: kind, group: kind == "session" ? "session" : "weekly", percent: percent,
                       severity: .normal, resetsAt: nil, scopeLabel: scope, isActive: active)
        }
        let u = ClaudeUsage(planLabel: "", limits: [limit("weekly_all", 50), limit("weekly_scoped", 70, scope: "Opus")],
                            fetchedAt: Date(), extraUsageEnabled: false, extraUsageDisabledReason: nil)
        XCTAssertEqual(u.footerLimits.map(\.label), ["7 天 · Opus"])
        let tie = ClaudeUsage(planLabel: "", limits: [limit("weekly_all", 70), limit("weekly_scoped", 70, active: true, scope: "Opus")],
                              fetchedAt: Date(), extraUsageEnabled: false, extraUsageDisabledReason: nil)
        XCTAssertEqual(tie.footerLimits.first?.scopeLabel, "Opus")
    }

    func testLevelUsesSeverityThenPercent() {
        func level(_ percent: Double, _ severity: UsageSeverity) -> UsageLevel {
            UsageLimit(kind: "session", group: nil, percent: percent, severity: severity, resetsAt: nil,
                       scopeLabel: nil, isActive: false).level
        }
        XCTAssertEqual(level(95, .normal), .normal)
        XCTAssertEqual(level(10, .warning), .warning)
        XCTAssertEqual(level(10, .critical), .critical)
        XCTAssertEqual(level(69.9, .unknown), .normal)
        XCTAssertEqual(level(70, .unknown), .warning)
        XCTAssertEqual(level(89, .unknown), .warning)
        XCTAssertEqual(level(90, .unknown), .critical)
    }

    func testParsesISODatesWithAndWithoutFraction() {
        XCTAssertNotNil(ClaudeUsage.parseDate("2026-10-03T05:30:00.245924+00:00"))
        XCTAssertNotNil(ClaudeUsage.parseDate("2026-10-03T05:30:00+08:00"))
        XCTAssertNotNil(ClaudeUsage.parseDate("2026-10-03T05:30:00Z"))
        XCTAssertNil(ClaudeUsage.parseDate("yesterday"))
        XCTAssertEqual(ClaudeUsage.parseDate("2026-10-03T13:30:00+08:00"), ClaudeUsage.parseDate("2026-10-03T05:30:00Z"))
    }

    func testPlanLabelMapping() {
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: "claude_team", rateLimitTier: "default_claude_max_5x"), "Team · Max 5x")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"), "Max · Max 20x")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: "claude_pro", rateLimitTier: nil), "Pro")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: "enterprise", rateLimitTier: "default"), "Enterprise")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: "something_new", rateLimitTier: nil), "something_new")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: nil, rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeUsage.planLabel(organizationType: nil, rateLimitTier: nil), "")
    }

    // MARK: 重置时间文案

    private var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return c
    }

    private func at(_ s: String) -> Date { ClaudeUsage.parseDate(s) ?? Date.distantPast }

    func testResetTextRelative() {
        let now = at("2026-10-03T10:00:00+08:00")
        let cal = shanghai
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-03T10:00:20+08:00"), now: now, calendar: cal), "即将重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-03T10:25:00+08:00"), now: now, calendar: cal), "25分钟后重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-03T12:10:00+08:00"), now: now, calendar: cal), "2小时后重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-03T21:30:00+08:00"), now: now, calendar: cal), "今天 21:30 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T09:00:00+08:00"), now: now, calendar: cal), "明天 09:00 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-05T09:00:00+08:00"), now: now, calendar: cal), "10月5日 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T08:59:59.6+08:00"), now: now, calendar: cal), "明天 09:00 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T23:59:59.9+08:00"), now: now, calendar: cal), "10月5日 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-03T09:00:00+08:00"), now: now, calendar: cal), "已重置")
    }

    func testResetTextNearMidnightUsesHours() {
        let now = at("2026-10-03T23:00:00+08:00")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T01:30:00+08:00"), now: now, calendar: shanghai), "2小时后重置")
    }

    func testResetTextRespectsTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = at("2026-10-03T10:00:00Z")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T01:00:00Z"), now: now, calendar: utc), "明天 01:00 重置")
        XCTAssertEqual(UsageResetText.text(resetsAt: at("2026-10-04T01:00:00Z"), now: now, calendar: shanghai), "明天 09:00 重置")
    }

    // MARK: 用量提醒

    private func usage(_ limits: [UsageLimit]) -> ClaudeUsage {
        ClaudeUsage(planLabel: "Team", limits: limits, fetchedAt: Date(), extraUsageEnabled: false, extraUsageDisabledReason: nil)
    }

    private func limit(_ kind: String, _ percent: Double, _ resetsAt: Date?, severity: UsageSeverity = .unknown,
                       scope: String? = nil) -> UsageLimit {
        UsageLimit(kind: kind, group: nil, percent: percent, severity: severity, resetsAt: resetsAt,
                   scopeLabel: scope, isActive: false)
    }

    func testAlertFiresOncePerResetPeriod() {
        let now = at("2026-10-03T10:00:00+08:00")
        let reset = at("2026-10-04T09:00:00.123+08:00")
        let u = usage([limit("session", 20, at("2026-10-03T12:00:00+08:00")), limit("weekly_all", 92, reset)])
        let alerts = UsageAlerts.pending(usage: u, lastNotified: [:], now: now, calendar: shanghai)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.limitID, "weekly_all")
        XCTAssertEqual(alerts.first?.title, "Claude 用量提醒")
        XCTAssertEqual(alerts.first?.body, "7 天（全部）额度已用 92%，明天 09:00 重置")
        let key = alerts.first?.periodKey ?? 0
        // 同一周期（重置时间秒以下抖动）不再提醒。
        let jitter = usage([limit("weekly_all", 95, reset.addingTimeInterval(0.4))])
        XCTAssertEqual(UsageAlerts.pending(usage: jitter, lastNotified: ["weekly_all": key], now: now, calendar: shanghai), [])
        // 新周期再次提醒。
        let next = usage([limit("weekly_all", 91, reset.addingTimeInterval(7 * 86400))])
        XCTAssertEqual(UsageAlerts.pending(usage: next, lastNotified: ["weekly_all": key], now: now, calendar: shanghai).count, 1)
    }

    func testAlertCoversEveryLimitAndCriticalSeverity() {
        let now = at("2026-10-03T10:00:00+08:00")
        let reset = at("2026-10-04T09:00:00+08:00")
        let u = usage([limit("session", 90, at("2026-10-03T12:30:00+08:00")),
                       limit("weekly_all", 89.9, reset),
                       limit("weekly_scoped", 50, reset, severity: .critical, scope: "Fable"),
                       limit("weekly_scoped", 99, reset, scope: "Opus")])
        let alerts = UsageAlerts.pending(usage: u, lastNotified: [:], now: now, calendar: shanghai)
        XCTAssertEqual(alerts.map(\.limitID), ["session", "weekly_scoped|Fable", "weekly_scoped|Opus"])
        XCTAssertEqual(alerts.first?.body, "5 小时额度已用 90%，2小时后重置")
        XCTAssertEqual(alerts[1].body, "7 天 · Fable额度已用 50%，明天 09:00 重置")
        // 已过重置时间（缓存过期）或没有重置时间时不提醒。
        let stale = usage([limit("weekly_all", 95, at("2026-10-03T09:00:00+08:00")), limit("session", 95, nil)])
        XCTAssertEqual(UsageAlerts.pending(usage: stale, lastNotified: [:], now: now, calendar: shanghai), [])
    }

    func testLimitExpiry() {
        let now = at("2026-10-03T10:00:00+08:00")
        XCTAssertTrue(limit("session", 50, at("2026-10-03T09:59:00+08:00")).isExpired(now: now))
        XCTAssertFalse(limit("session", 50, at("2026-10-03T10:01:00+08:00")).isExpired(now: now))
        XCTAssertFalse(limit("session", 50, nil).isExpired(now: now))
    }

    func testAgeAndSummary() throws {
        let usage = try XCTUnwrap(ClaudeUsage.parse(json(withLimits)))
        let fetched = usage.fetchedAt
        XCTAssertEqual(usage.ageText(now: fetched.addingTimeInterval(20)), "数据更新于 刚刚（来自 Claude Code 缓存）")
        XCTAssertEqual(usage.ageText(now: fetched.addingTimeInterval(5 * 60 + 10)), "数据更新于 5 分钟前（来自 Claude Code 缓存）")
        XCTAssertEqual(usage.ageText(now: fetched.addingTimeInterval(3 * 3600)), "数据更新于 3 小时前（来自 Claude Code 缓存）")
        XCTAssertEqual(usage.ageText(now: fetched.addingTimeInterval(2 * 86400)), "数据更新于 2 天前（来自 Claude Code 缓存）")
        XCTAssertFalse(usage.isStale(now: fetched.addingTimeInterval(30 * 60)))
        XCTAssertTrue(usage.isStale(now: fetched.addingTimeInterval(31 * 60)))

        let now = at("2026-10-03T12:00:00+08:00")
        let summary = usage.summary(now: now, calendar: shanghai).components(separatedBy: "\n")
        XCTAssertEqual(summary.first, "Claude Team · Max 5x")
        XCTAssertEqual(summary[1], "5 小时  20%  1小时后重置")
        XCTAssertEqual(summary[2], "7 天（全部）  89%  明天 09:00 重置（当前生效）")
        XCTAssertEqual(summary[4], "monthly_thing · Desktop  5%")
        XCTAssertEqual(summary[5], "额外用量：未开启（组织已停用）")
        XCTAssertEqual(limit("session", 50, at("2026-10-03T11:00:00+08:00")).percentText(now: now), "—")
    }

    // MARK: 文件读取（按 mtime 缓存）

    func testSourceReadsOnlyWhenModified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude.json")
        let source = ClaudeUsageSource(path: file.path)
        XCTAssertNil(source.read())
        try json(withLimits).write(to: file)
        XCTAssertEqual(source.read()?.planLabel, "Team · Max 5x")
        XCTAssertEqual(source.parseCount, 1)
        XCTAssertEqual(source.read()?.planLabel, "Team · Max 5x")
        XCTAssertEqual(source.parseCount, 1)
        try json(#"{"cachedUsageUtilization": null}"#).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertNil(source.read())
        XCTAssertEqual(source.parseCount, 2)
    }
}
