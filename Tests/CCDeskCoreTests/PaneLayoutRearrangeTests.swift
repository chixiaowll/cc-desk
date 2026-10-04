import XCTest
import CoreGraphics
@testable import CCDeskCore

final class PaneLayoutRearrangeTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let size = CGSize(width: 1000, height: 800)
    private let minPane = CGSize(width: 280, height: 160)
    private var area: CGRect { CGRect(origin: .zero, size: size) }

    /// a | (b / c)。
    private func threePanes() -> PaneLayout {
        var layout = PaneLayout()
        layout.show(a)
        layout.split(a, edge: .right, with: b)
        layout.split(b, edge: .bottom, with: c)
        return layout
    }

    // MARK: move

    func testMovePaneToLeftOfAnother() {
        var layout = threePanes()
        XCTAssertTrue(layout.move(c, beside: a, edge: .left))
        XCTAssertEqual(layout.leaves, [c, a, b])
        XCTAssertEqual(layout.focused, c)
        let frames = layout.frames(in: area)
        XCTAssertEqual(frames[c]?.minX, 0)
        XCTAssertEqual(frames[b]?.height, 800, "b's old split collapsed")
    }

    func testMovePaneBelowAnother() {
        var layout = threePanes()
        XCTAssertTrue(layout.move(b, beside: a, edge: .bottom))
        XCTAssertEqual(layout.leaves, [a, b, c])
        let frames = layout.frames(in: area)
        XCTAssertEqual(frames[a]?.minY, 0)
        XCTAssertEqual(frames[b]?.minY, 400)
        XCTAssertEqual(frames[b]?.maxX, frames[a]?.maxX)
        XCTAssertEqual(frames[c]?.height, 800)
    }

    func testMoveRejectsSelfAndUnknownPanes() {
        var layout = threePanes()
        let before = layout
        XCTAssertFalse(layout.move(a, beside: a, edge: .left))
        XCTAssertFalse(layout.move(d, beside: a, edge: .left))
        XCTAssertFalse(layout.move(a, beside: d, edge: .left))
        XCTAssertEqual(layout, before)
    }

    func testMoveWhenFullDoesNotNeedAFreeSlot() {
        var layout = threePanes()
        layout.split(a, edge: .bottom, with: d)
        XCTAssertTrue(layout.isFull)
        XCTAssertTrue(layout.move(d, beside: c, edge: .right))
        XCTAssertEqual(layout.count, 4)
        XCTAssertEqual(Set(layout.leaves), [a, b, c, d])
    }

    func testCanMoveChecksSizeAfterRemoval() {
        let layout = threePanes()
        // b 移走后 c 占满右半边（500×800）：上下能分，左右分不开（< 2×280）。
        XCTAssertTrue(layout.canMove(b, beside: c, edge: .bottom, in: size, minPane: minPane))
        XCTAssertFalse(layout.canMove(b, beside: c, edge: .right, in: size, minPane: minPane))
        XCTAssertTrue(layout.canMove(b, beside: c, edge: .right, in: .zero, minPane: minPane))
        XCTAssertFalse(layout.canMove(a, beside: a, edge: .right, in: size, minPane: minPane))
    }

    func testSwapExchangesPanes() {
        var layout = threePanes()
        let before = layout.frames(in: area)
        XCTAssertTrue(layout.swap(a, c))
        let after = layout.frames(in: area)
        XCTAssertEqual(after[c], before[a])
        XCTAssertEqual(after[a], before[c])
    }

    // MARK: 分隔线

    func testDragRatioFollowsDelta() {
        let layout = threePanes()
        guard let divider = layout.dividers(in: area).first(where: { $0.path == [] }) else { return XCTFail() }
        XCTAssertEqual(divider.position, 500)
        XCTAssertEqual(layout.ratio(dragging: divider, by: 100, in: size, minPane: minPane), 0.6, accuracy: 1e-9)
        XCTAssertEqual(layout.ratio(dragging: divider, by: -150, in: size, minPane: minPane), 0.35, accuracy: 1e-9)
    }

    func testDragRatioClampsToMinimumPaneSize() {
        let layout = threePanes()
        guard let root = layout.dividers(in: area).first(where: { $0.path == [] }),
              let inner = layout.dividers(in: area).first(where: { $0.path == [1] }) else { return XCTFail() }
        XCTAssertEqual(layout.ratio(dragging: root, by: -1000, in: size, minPane: minPane), 0.28, accuracy: 1e-9)
        XCTAssertEqual(layout.ratio(dragging: root, by: 1000, in: size, minPane: minPane), 0.72, accuracy: 1e-9)
        XCTAssertEqual(layout.ratio(dragging: inner, by: 1000, in: size, minPane: minPane), 0.8, accuracy: 1e-9)
        XCTAssertEqual(layout.ratio(dragging: inner, by: -1000, in: size, minPane: minPane), 0.2, accuracy: 1e-9)
    }

    func testDragRatioAppliesThroughSetRatio() {
        var layout = threePanes()
        guard let divider = layout.dividers(in: area).first(where: { $0.path == [1] }) else { return XCTFail() }
        XCTAssertTrue(layout.setRatio(layout.ratio(dragging: divider, by: 80, in: size, minPane: minPane), at: divider.path))
        XCTAssertEqual(layout.frames(in: area)[b]?.height ?? 0, 480, accuracy: 1e-6)
    }

    func testDividerHitAreas() {
        let layout = threePanes()
        XCTAssertEqual(layout.divider(at: CGPoint(x: 503, y: 100), in: area, grab: 6)?.path, [])
        XCTAssertEqual(layout.divider(at: CGPoint(x: 750, y: 396), in: area, grab: 6)?.path, [1])
        XCTAssertNil(layout.divider(at: CGPoint(x: 250, y: 400), in: area, grab: 6), "inside pane a")
        XCTAssertNil(layout.divider(at: CGPoint(x: 750, y: 200), in: area, grab: 6), "inside pane b")
        XCTAssertNil(layout.divider(at: CGPoint(x: 250, y: 400), in: area, grab: 6), "the inner divider spans only the right half")
        // T 形交点：取离得更近的那条。
        XCTAssertEqual(layout.divider(at: CGPoint(x: 504, y: 401), in: area, grab: 6)?.path, [1])
        XCTAssertEqual(layout.divider(at: CGPoint(x: 501, y: 404), in: area, grab: 6)?.path, [])
        var single = PaneLayout()
        single.show(a)
        XCTAssertNil(single.divider(at: CGPoint(x: 500, y: 400), in: area, grab: 6))
    }

    func testHitRect() {
        let divider = PaneDivider(path: [], axis: .vertical, rect: CGRect(x: 10, y: 0, width: 200, height: 100), position: 40)
        XCTAssertEqual(divider.hitRect(grab: 5), CGRect(x: 10, y: 35, width: 200, height: 10))
    }
}
