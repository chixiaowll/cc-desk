import Foundation
import CCDeskCore

/// `CCDesk --set-push-secret <account>`：从标准输入读一行密钥，由 CC Desk 自己写进钥匙串后退出（不启动界面）。
/// 由本程序创建的钥匙串条目归 CC Desk 所有，之后 App 读取时不会弹出钥匙串授权；
/// 密钥走标准输入而不是命令行参数，不会出现在进程列表里。
enum PushSecretImport {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--set-push-secret") else { return }
        guard args.indices.contains(flag + 1), let key = PushSecretKey(rawValue: args[flag + 1]) else {
            FileHandle.standardError.write(Data("usage: CCDesk --set-push-secret <\(PushSecretKey.allCases.map(\.rawValue).joined(separator: "|"))> < secret\n".utf8))
            exit(2)
        }
        let value = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainSecretStore.push.write(value, account: key.rawValue)
            print(value.isEmpty ? "removed \(key.rawValue)" : "saved \(key.rawValue)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
