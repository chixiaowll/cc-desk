import SwiftUI
import CCDeskCore

/// 设置 → 集成：Codex hook / pi 扩展的安装状态与安装、卸载（设计 §4.4）。从不自动安装。
struct IntegrationsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("状态集成").font(.headline)
            Text("安装后，CC Desk 能准确显示 Codex / pi 会话的「处理中 / 等批准 / 空闲」，包括在 Terminal 等外部终端里启动的会话。"
                 + "修改配置前会备份为 *.cc-desk.bak；卸载只移除 CC Desk 自己添加的内容。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                IntegrationRow(name: "Claude", detail: "内置：读取 ~/.claude/sessions，无需安装", status: nil,
                               busy: false, install: nil, uninstall: nil)
                Divider()
                IntegrationRow(name: "Codex",
                               detail: "~/.codex/hooks.json（hook 脚本在 ~/.cc-desk/hooks/）+ config.toml 的 [features] hooks = true",
                               status: model.integrationStatus[.codex], busy: model.integrationBusy.contains(.codex),
                               install: { model.installIntegration(.codex) },
                               uninstall: { model.uninstallIntegration(.codex) })
                Divider()
                IntegrationRow(name: "pi", detail: "~/.pi/agent/extensions/cc-desk-state.ts",
                               status: model.integrationStatus[.pi], busy: model.integrationBusy.contains(.pi),
                               install: { model.installIntegration(.pi) },
                               uninstall: { model.uninstallIntegration(.pi) })
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))

            Text("已在运行的 Codex / pi 需重新启动后生效。Codex 第一次加载新 hook 时会提示「Hooks need review」，选择 Trust 后才会运行。"
                 + "未安装时，内嵌终端里的 Codex / pi 仍可通过屏幕识别显示状态。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") { model.showIntegrations = false }.keyboardShortcut(.defaultAction)
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
    /// nil 表示内置、无需安装。
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
                    Button("安装", action: install)
                case .installed:
                    Button("卸载", action: uninstall)
                case .needsRepair:
                    Button("重新安装", action: install)
                    Button("卸载", action: uninstall)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        guard let status else { return "已启用" }
        return status.label
    }

    private var statusColor: Color {
        switch status {
        case nil, .installed?: return .green
        case .needsRepair?: return .orange
        default: return .secondary
        }
    }
}
