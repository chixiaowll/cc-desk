import AppKit
import CCDeskCore

/// Codex / pi 状态集成的检测、安装与卸载。
extension AppModel {
    func refreshIntegrations() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statuses: [AgentKind: IntegrationStatus] = [.codex: CodexIntegration().status(), .pi: PiIntegration().status()]
            DispatchQueue.main.async { self?.integrationStatus = statuses }
        }
    }

    func installIntegration(_ kind: AgentKind) {
        runIntegration(kind, failureTitle: L("integration.installFailed", kind.displayName)) {
            switch kind {
            case .codex: try CodexIntegration().install()
            case .pi: try PiIntegration().install()
            case .claude, .opencode, .other: break
            }
        }
    }

    func uninstallIntegration(_ kind: AgentKind) {
        guard confirm(L("confirm.uninstallIntegration.title", kind.displayName),
                      L("confirm.uninstallIntegration.message", kind.displayName)) else { return }
        runIntegration(kind, failureTitle: L("integration.uninstallFailed", kind.displayName)) {
            switch kind {
            case .codex: try CodexIntegration().uninstall()
            case .pi: try PiIntegration().uninstall()
            case .claude, .opencode, .other: break
            }
        }
    }

    private func runIntegration(_ kind: AgentKind, failureTitle: String, _ work: @escaping () throws -> Void) {
        guard !integrationBusy.contains(kind) else { return }
        integrationBusy.insert(kind)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do { try work() } catch { failure = (error as? IntegrationError)?.message ?? error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.integrationBusy.remove(kind)
                self.refreshIntegrations()
                if let failure { self.alert(failureTitle, failure) }
            }
        }
    }
}
