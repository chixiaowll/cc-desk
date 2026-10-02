import SwiftUI
import AppKit
import CCDeskCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .overlay {
            if model.showHistoryPalette { HistoryPalette(model: model) }
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet(model: model) }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let row = model.selectedRow, row.session.host.isEmbedded {
                HStack {
                    Text(row.displayName).font(.headline)
                    if row.session.kind == .claude {
                        Text("·").foregroundStyle(.secondary)
                        Text("Claude").foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.secondary)
                    Text(row.session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            ZStack {
                TerminalContainer(pool: model.pool, terminalIDs: model.pool.terminals.map(\.id),
                                  selected: model.selectedTerminalID)
                if model.selectedTerminalID == nil {
                    Text("选择左侧的 session，或按 ⌘N 新建").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 所有内嵌终端视图常驻同一个容器，切换只改 isHidden，不重建、不清屏。
struct TerminalContainer: NSViewRepresentable {
    let pool: TerminalPool
    let terminalIDs: [UUID]
    let selected: UUID?

    final class Coordinator {
        var lastSelected: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let views = pool.terminals.map(\.view)
        for view in views where view.superview !== container {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        for view in container.subviews where !views.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        for terminal in pool.terminals {
            terminal.view.isHidden = terminal.id != selected
        }
        if context.coordinator.lastSelected != selected {
            context.coordinator.lastSelected = selected
            if let id = selected, let terminal = pool.terminal(id) {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
        }
    }
}

struct NewSessionSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建 Claude Code Session").font(.headline)
            if model.recentDirs.isEmpty {
                Text("还没有最近使用的目录").foregroundStyle(.secondary)
            } else {
                Text("最近使用").font(.subheadline).foregroundStyle(.secondary)
                ForEach(Array(model.recentDirs.enumerated()), id: \.element) { index, dir in
                    Button {
                        model.showNewSession = false
                        model.newSession(cwd: dir)
                    } label: {
                        Text(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .keyboardShortcut(index == 0 ? .defaultAction : nil)
                }
            }
            HStack {
                Button("选择其他目录…") { model.chooseDirectoryAndCreate() }
                Spacer()
                Button("取消") { model.showNewSession = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
