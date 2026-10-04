import AppKit
import CCDeskCore

/// 确认框与提示框。
extension AppModel {
    func confirm(_ title: String, _ info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: L("action.confirm"))
        alert.addButton(withTitle: L("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }

    func alertAutomationDenied() {
        let alert = NSAlert()
        alert.messageText = L("alert.automationDenied.title")
        alert.informativeText = L("alert.automationDenied.message")
        alert.addButton(withTitle: L("action.openSystemSettings"))
        alert.addButton(withTitle: L("action.ok"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
