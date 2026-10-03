import Foundation
import CCDeskCore

/// CCDesk 模块的界面文案（`Resources/<lang>.lproj/Localizable.strings`）。
func L(_ key: String, _ args: CVarArg...) -> String {
    Localization.string(key, bundleName: "CCDesk_CCDesk", args)
}

/// 带数量的文案：n == 1 用 `<key>.one`，否则用 `<key>.other`（中文两者相同），格式里用 %d 取数量。
func LN(_ key: String, _ count: Int) -> String {
    count == 1 ? L(key + ".one", count) : L(key + ".other", count)
}
