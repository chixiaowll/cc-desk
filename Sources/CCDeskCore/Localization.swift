import Foundation

/// 界面文案本地化：各模块的 `Localizable.strings` 放在 SwiftPM 资源包（`CCDesk_<Module>.bundle`）里。
///
/// 不直接用 `Bundle.module`：
/// - 生成的访问器只在 `Bundle.main.bundleURL`（.app 根目录，签名不允许放文件）和构建目录里找资源包，
///   打包后的 .app 在别的机器上会直接 fatalError；
/// - 非 main bundle 的语言选择会跟随 main bundle，未打包的可执行文件 / xctest 里总是落到开发语言。
/// 所以这里自己定位资源包，并按 `Locale.preferredLanguages`（含 `AppleLanguages`）显式选择 lproj。
public enum Localization {
    /// 开发 / 回退语言。
    public static let developmentLanguage = "en"
    /// 支持的界面语言。
    public static let supportedLanguages = ["en", "zh-Hans"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _languageOverride: String?
    nonisolated(unsafe) private static var resourceBundles: [String: Bundle] = [:]
    nonisolated(unsafe) private static var tables: [String: [String: String]] = [:]

    /// 强制使用某个语言（测试用，nil = 跟随系统 / AppleLanguages）。
    public static var languageOverride: String? {
        get { lock.lock(); defer { lock.unlock() }; return _languageOverride }
        set { lock.lock(); _languageOverride = newValue; lock.unlock() }
    }

    /// 当前生效的界面语言（"en" / "zh-Hans"）。
    public static var currentLanguage: String {
        if let languageOverride { return languageOverride }
        return resolveLanguage(preferences: Locale.preferredLanguages)
    }

    /// 从用户偏好语言里挑出支持的界面语言；都不匹配时回退英文。
    public static func resolveLanguage(preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: preferences).first
            ?? developmentLanguage
    }

    /// 在资源包 `bundleName` 的当前语言表里查 key，找不到时依次回退英文、key 本身；有参数时按 `String(format:)` 格式化。
    public static func string(_ key: String, bundleName: String, _ args: [CVarArg] = []) -> String {
        let language = currentLanguage
        let format = table(bundleName: bundleName, language: language)[key]
            ?? table(bundleName: bundleName, language: developmentLanguage)[key]
            ?? key
        guard !args.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language), arguments: args)
    }

    /// 某个语言下的全部键值（测试用来检查两种语言的键集合一致）。
    public static func table(bundleName: String, language: String) -> [String: String] {
        let cacheKey = bundleName + "|" + language
        lock.lock()
        if let cached = tables[cacheKey] { lock.unlock(); return cached }
        lock.unlock()
        var result: [String: String] = [:]
        if let bundle = resourceBundle(named: bundleName),
           let url = lprojURL(in: bundle, language: language)?.appendingPathComponent("Localizable.strings"),
           let dict = NSDictionary(contentsOf: url) as? [String: String] {
            result = dict
        }
        lock.lock()
        tables[cacheKey] = result
        lock.unlock()
        return result
    }

    /// 资源包里的 lproj 目录。SwiftPM 会把目录名转成小写（zh-Hans.lproj → zh-hans.lproj），两种写法都试。
    static func lprojURL(in bundle: Bundle, language: String) -> URL? {
        for name in [language, language.lowercased()] {
            if let url = bundle.url(forResource: name, withExtension: "lproj") { return url }
        }
        return nil
    }

    /// 定位资源包：.app 的 Contents/Resources、可执行文件同目录（swift run）、测试 bundle 同目录（swift test）。
    public static func resourceBundle(named name: String) -> Bundle? {
        lock.lock()
        if let cached = resourceBundles[name] { lock.unlock(); return cached }
        lock.unlock()
        let file = name + ".bundle"
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        dirs.append(Bundle.main.bundleURL)
        if let executable = Bundle.main.executableURL { dirs.append(executable.deletingLastPathComponent()) }
        let own = Bundle(for: BundleToken.self)
        dirs.append(own.bundleURL.deletingLastPathComponent())
        if let resources = own.resourceURL { dirs.append(resources) }
        for dir in dirs {
            if let bundle = Bundle(url: dir.appendingPathComponent(file)) {
                lock.lock()
                resourceBundles[name] = bundle
                lock.unlock()
                return bundle
            }
        }
        return nil
    }
}

private final class BundleToken {}

/// CCDeskCore 自己的文案。
func L(_ key: String, _ args: CVarArg...) -> String {
    Localization.string(key, bundleName: "CCDesk_CCDeskCore", args)
}
