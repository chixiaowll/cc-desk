import XCTest
@testable import CCDeskCore

/// 断言界面文案的测试固定使用简体中文，结果与本机系统语言无关。
class ZhHansTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        Localization.languageOverride = "zh-Hans"
    }

    override func tearDown() {
        Localization.languageOverride = nil
        super.tearDown()
    }
}
