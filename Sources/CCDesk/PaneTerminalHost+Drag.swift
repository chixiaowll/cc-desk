import AppKit
import CCDeskCore

/// 窗格容器的拖放（设计 §20.2）：
/// - 拖放目标：侧栏会话行（`.string`，内容 "row:term:<uuid>"）与窗格标题条（私有类型 `paneType`，内容为终端 id）。
///   落在窗格四边：分屏 / 挪到那一侧；落在中间：替换 / 互换。高亮半个或整个窗格。
/// - 拖动来源：窗格标题条。用 AppKit 的拖动会话，结束时能拿到松手的屏幕坐标：没有任何地方接收、且松手处不在
///   窗格区域里（主窗口之外、侧栏、别的窗口）时，把会话分离到松手处的新窗口。
extension PaneTerminalHost.HostView: NSDraggingSource {
    // MARK: 拖放目标

    /// 拖动内容里的终端 id。拖动中读不到内容时（SwiftUI 的拖动内容可能延迟提供）id 为 nil：先按可放下处理，
    /// 松手时再核对。不是会话 / 窗格的拖动返回 nil。
    private func payload(_ info: NSDraggingInfo) -> (id: UUID?, known: Bool)? {
        let pasteboard = info.draggingPasteboard
        if pasteboard.types?.contains(Self.paneType) == true {
            guard let id = pasteboard.string(forType: Self.paneType).flatMap(UUID.init(uuidString:)) else { return nil }
            return (id, true)
        }
        guard pasteboard.types?.contains(.string) == true else { return nil }
        guard let text = pasteboard.string(forType: .string) else { return (nil, false) }
        guard let id = AppModel.draggedTerminalID(text) else { return nil }
        return (id, true)
    }

    private func target(_ info: NSDraggingInfo) -> (pane: UUID?, zone: PaneDropZone, area: CGRect) {
        let point = convert(info.draggingLocation, from: nil)
        guard let id = pane(at: point), let frame = paneFrames[id] else { return (nil, .center, bounds) }
        let zone = PaneDropZone.at(point, in: frame)
        return (id, zone, zone.highlight(in: frame))
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for candidate: NSDragOperation in [.move, .generic, .copy] where mask.contains(candidate) { return candidate }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = payload(sender) else { return hideHighlight() }
        let target = target(sender)
        if let id = payload.id, !actions.canDrop(id, target.pane, target.zone) { return hideHighlight() }
        highlight.frame = target.area.insetBy(dx: 3, dy: 3)
        highlight.isHidden = false
        return operation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideHighlight() }
    override func draggingEnded(_ sender: NSDraggingInfo) { hideHighlight() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideHighlight()
        guard let id = payload(sender)?.id ?? sender.draggingPasteboard.string(forType: .string)
            .flatMap(AppModel.draggedTerminalID) else { return false }
        let target = target(sender)
        return actions.drop(id, target.pane, target.zone)
    }

    @discardableResult
    private func hideHighlight() -> NSDragOperation {
        highlight.isHidden = true
        return []
    }

    // MARK: 拖动来源（窗格标题条）

    /// 从标题条开始拖动窗格：拖动内容为私有类型的终端 id，预览为窗格的缩略图。
    func beginPaneDrag(_ id: UUID, event: NSEvent) {
        guard let frame = paneFrames[id] else { return }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: Self.paneType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage(for: id, paneSize: frame.size)
        let point = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - 12,
                                         width: image.size.width, height: image.size.height), contents: image)
        draggingPane = (id, frame.size)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 只在本 App 里放下；拖到别的 App 上不让它们接收，松手时按「拖出窗格区域」处理。
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // 拖出窗格区域后松手会分离成新窗口，预览不再飞回原处。
        session.animatesToStartingPositionsOnCancelOrFail = containsScreenPoint(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let dragged = draggingPane
        draggingPane = nil
        hideHighlight()
        guard let dragged else { return }
        // 被窗格接收（挪动 / 互换）的已经处理；按 Esc 取消的不分离。
        if operation.isEmpty, !containsScreenPoint(screenPoint), !Self.cancelledByEscape() {
            let actions = self.actions
            DispatchQueue.main.async { actions.tearOff(dragged.id, screenPoint, dragged.size) }
        } else {
            DispatchQueue.main.async { [weak self] in self?.restoreKeyboardFocus() }
        }
    }

    /// 屏幕上这一点是否落在这个容器（窗格区域）里，且没有被本 App 更靠前的窗口（如独立窗口）挡住。
    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        for other in NSApp.orderedWindows {
            if other === window { break }
            if other.isVisible, other.frame.contains(screenPoint) { return false }
        }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return bounds.contains(point)
    }

    private static func cancelledByEscape() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.keyCode == 53
    }

    /// 拖动预览：会话名的标题条 + 终端内容的缩略图，最宽 320pt。
    private func dragImage(for id: UUID, paneSize: CGSize) -> NSImage {
        let scale = min(1, 320 / max(paneSize.width, 1))
        let size = CGSize(width: max(120, paneSize.width * scale), height: max(60, paneSize.height * scale))
        var snapshot: NSBitmapImageRep?
        if let view = views[id], !view.isHidden, view.bounds.width > 0, view.bounds.height > 0,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            snapshot = rep
        }
        let title = titles[id] ?? ""
        let background = self.background
        let dark = (background.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) < 0.5
        let tint = highlight.tint
        return NSImage(size: size, flipped: true) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            background.withAlphaComponent(0.92).setFill()
            path.fill()
            let scale = UIScalePreferences.shared.scale
            let header = scale.metric(22)
            if let snapshot {
                let content = CGRect(x: 6, y: header, width: rect.width - 12, height: rect.height - header - 6)
                snapshot.draw(in: content, from: .zero, operation: .sourceOver, fraction: 0.85,
                              respectFlipped: true, hints: nil)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: scale.font(11.5), weight: .semibold),
                .foregroundColor: dark ? NSColor.white : NSColor.black,
            ]
            (title as NSString).draw(in: CGRect(x: 10, y: 4, width: rect.width - 20, height: header - 6), withAttributes: attributes)
            tint.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
    }
}
