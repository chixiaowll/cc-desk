import XCTest
@testable import CCDeskCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Localization.languageOverride = nil
        super.tearDown()
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// (源码目录, 该模块的资源目录)
    private static let modules = [
        ("Sources/CCDeskCore", "Sources/CCDeskCore/Resources"),
    ]

    private func strings(_ resources: String, _ language: String) throws -> [String: String] {
        let url = Self.repoRoot.appendingPathComponent("\(resources)/\(language).lproj/Localizable.strings")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "无法解析 \(url.path)")
        XCTAssertFalse(dict.isEmpty, url.path)
        return dict
    }

    private func usedKeys(in sourceDir: String) throws -> Set<String> {
        let dir = Self.repoRoot.appendingPathComponent(sourceDir)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"\bL\("([^"\\]+)""#)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) { keys.insert(String(text[r])) }
            }
        }
        return keys
    }

    /// 格式占位符的类型多重集（忽略位置序号），两种语言必须一致。
    private func specifiers(_ format: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(?:\d+\$)?(@|ld|d|%)"#) else { return [] }
        let range = NSRange(format.startIndex..., in: format)
        return regex.matches(in: format, range: range).compactMap { m in
            Range(m.range(at: 1), in: format).map { String(format[$0]) }
        }.sorted()
    }

    func testEveryUsedKeyExistsInBothLanguagesAndKeySetsMatch() throws {
        for (sourceDir, resources) in Self.modules {
            let en = try strings(resources, "en")
            let zh = try strings(resources, "zh-Hans")
            XCTAssertEqual(Set(en.keys).subtracting(zh.keys), [], "\(resources)：仅英文有的键")
            XCTAssertEqual(Set(zh.keys).subtracting(en.keys), [], "\(resources)：仅中文有的键")
            let used = try usedKeys(in: sourceDir)
            XCTAssertFalse(used.isEmpty, sourceDir)
            XCTAssertEqual(used.subtracting(en.keys), [], "\(sourceDir)：代码里用到但缺少翻译的键")
            XCTAssertEqual(Set(en.keys).subtracting(used), [], "\(resources)：没有被代码使用的键")
            for key in en.keys {
                XCTAssertEqual(specifiers(en[key] ?? ""), specifiers(zh[key] ?? ""), "\(resources)：\(key) 的占位符不一致")
            }
        }
    }

    func testResourceBundleLoadsBothLanguages() {
        XCTAssertNotNil(Localization.resourceBundle(named: "CCDesk_CCDeskCore"))
        XCTAssertEqual(Localization.table(bundleName: "CCDesk_CCDeskCore", language: "en")["status.waiting"], "Waiting")
        XCTAssertEqual(Localization.table(bundleName: "CCDesk_CCDeskCore", language: "zh-Hans")["status.waiting"], "等批准")
    }

    func testResolveLanguageFromPreferences() {
        XCTAssertEqual(Localization.resolveLanguage(preferences: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(Localization.resolveLanguage(preferences: ["en-CN", "zh-Hans-CN"]), "en")
        XCTAssertEqual(Localization.resolveLanguage(preferences: ["fr-FR"]), "en")
    }

    func testMissingKeyFallsBackToKey() {
        Localization.languageOverride = "zh-Hans"
        XCTAssertEqual(L("does.not.exist"), "does.not.exist")
    }

    func testEnglishCopy() {
        Localization.languageOverride = "en"
        XCTAssertEqual(AgentStatus.waiting(nil).label, "Waiting")
        XCTAssertEqual(AgentStatus.working.label, "Working")
        XCTAssertEqual(AgentStatus.idle.label, "Idle")
        XCTAssertEqual(AgentStatus.ended.label, "Ended")
        XCTAssertEqual(AgentKind.other.displayName, "Terminal")
        XCTAssertEqual(AgentKind.claude.displayName, "Claude")

        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeTime.short(from: now, now: now), "now")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-3 * 86400), now: now), "3d")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        XCTAssertEqual(UsageResetText.text(resetsAt: now.addingTimeInterval(25 * 60), now: now, calendar: calendar),
                       "Resets in 25m")
        XCTAssertEqual(UsageResetText.text(resetsAt: now.addingTimeInterval(-1), now: now, calendar: calendar), "Reset")

        let item = HistoryItem(sessionID: "a", cwd: "/a", title: "a", lastPrompt: nil, modifiedAt: now)
        XCTAssertEqual(HistoryGrouping.byDay([item], now: now, calendar: calendar).map(\.label), ["Today"])
    }

    func testChineseCopy() {
        Localization.languageOverride = "zh-Hans"
        XCTAssertEqual(AgentStatus.waiting(nil).label, "等批准")
        XCTAssertEqual(AgentKind.other.displayName, "终端")
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RelativeTime.short(from: now.addingTimeInterval(-300), now: now), "5分钟")
    }
}
