import SwiftUI
import CCDeskCore

/// 设置 → 集成：Codex hook / pi 扩展的安装状态与安装、卸载（设计 §4.4）。从不自动安装。
struct IntegrationsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("integrations.title")).font(.headline)
            Text(L("integrations.intro"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                IntegrationRow(name: "Claude", detail: L("integrations.claude.detail"), builtIn: true, status: nil,
                               busy: false, install: nil, uninstall: nil)
                Divider()
                IntegrationRow(name: "Codex",
                               detail: L("integrations.codex.detail"),
                               builtIn: false, status: model.integrationStatus[.codex], busy: model.integrationBusy.contains(.codex),
                               install: { model.installIntegration(.codex) },
                               uninstall: { model.uninstallIntegration(.codex) })
                Divider()
                IntegrationRow(name: "pi", detail: "~/.pi/agent/extensions/cc-desk-state.ts",
                               builtIn: false, status: model.integrationStatus[.pi], busy: model.integrationBusy.contains(.pi),
                               install: { model.installIntegration(.pi) },
                               uninstall: { model.uninstallIntegration(.pi) })
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))

            Text(L("integrations.footnote"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L("action.done")) { model.showIntegrations = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { model.refreshIntegrations() }
    }
}

private struct IntegrationRow: View {
    let name: String
    let detail: String
    /// 内置、无需安装（Claude）。
    let builtIn: Bool
    /// nil 表示尚未检测完成。
    let status: IntegrationStatus?
    let busy: Bool
    let install: (() -> Void)?
    let uninstall: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if let status, let install, let uninstall {
                switch status {
                case .agentMissing:
                    EmptyView()
                case .notInstalled:
                    Button(L("integrations.install"), action: install)
                case .installed:
                    Button(L("integrations.uninstall"), action: uninstall)
                case .needsRepair:
                    Button(L("integrations.reinstall"), action: install)
                    Button(L("integrations.uninstall"), action: uninstall)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        if builtIn { return L("integrations.enabled") }
        return status?.label ?? L("integrations.checking")
    }

    private var statusColor: Color {
        if builtIn { return .green }
        switch status {
        case .installed?: return .green
        case .needsRepair?: return .orange
        default: return .secondary
        }
    }
}
