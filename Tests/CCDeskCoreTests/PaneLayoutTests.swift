import XCTest
import CoreGraphics
@testable import CCDeskCore

final class PaneLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func single(_ id: UUID) -> PaneLayout {
        var layout = PaneLayout()
        layout.show(id)
        return layout
    }

    /// a | b 左右并排，b 再上下分成 b / c。
    private func threePanes() -> PaneLayout {
        var layout = single(a)
        XCTAssertTrue(layout.split(a, edge: .right, with: b))
        XCTAssertTrue(layout.split(b, edge: .bottom, with: c))
        return layout
    }

    private let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: show / focus

    func testShowOnEmptyLayoutCreatesSinglePane() {
        var layout = PaneLayout()
        XCTAssertTrue(layout.isEmpty)
        layout.show(a)
        XCTAssertEqual(layout.leaves, [a])
        XCTAssertEqual(layout.focused, a)
        XCTAssertFalse(layout.isSplit)
    }

    func testShowVisibleTerminalOnlyFocusesIt() {
        var layout = single(a)
        layout.split(a, edge: .right, with: b)
        layout.show(a)
        XCTAssertEqual(layout.leaves, [a, b])
        XCTAssertEqual(layout.focused, a)
    }

    func testShowHiddenTerminalReplacesFocusedPane() {
        var layout = single(a)
        layout.split(a, edge: .right, with: b)
        XCTAssertEqual(layout.focused, b)
        layout.show(c)
        XCTAssertEqual(layout.leaves, [a, c])
        XCTAssertEqual(layout.focused, c)
    }

    func testFocusUnknownTerminalFails() {
        var layout = single(a)
        XCTAssertFalse(layout.focus(b))
        XCTAssertEqual(layout.focused, a)
    }

    // MARK: split

    func testSplitRightAndDownBuildTree() {
        let layout = threePanes()
        XCTAssertEqual(layout.leaves, [a, b, c])
        XCTAssertEqual(layout.focused, c)
        let frames = layout.frames(in: unit)
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 50, height: 100))
        XCTAssertEqual(frames[b], CGRect(x: 50, y: 0, width: 50, height: 50))
        XCTAssertEqual(frames[c], CGRect(x: 50, y: 50, width: 50, height: 50))
    }

    func testSplitLeftAndTopPutNewPaneFirst() {
        var layout = single(a)
        layout.split(a, edge: .left, with: b)
        XCTAssertEqual(layout.leaves, [b, a])
        layout.split(a, edge: .top, with: c)
        XCTAssertEqual(layout.leaves, [b, c, a])
        XCTAssertEqual(layout.frames(in: unit)[c], CGRect(x: 50, y: 0, width: 50, height: 50))
    }

    func testSplitLimitedToFourPanes() {
        var layout = threePanes()
        XCTAssertTrue(layout.split(a, edge: .bottom, with: d))
        XCTAssertTrue(layout.isFull)
        let before = layout
        XCTAssertFalse(layout.split(a, edge: .right, with: e))
        XCTAssertEqual(layout, before)
    }

    func testSplitRejectsUnknownLeafAndSelf() {
        var layout = single(a)
        XCTAssertFalse(layout.split(b, edge: .right, with: c))
        XCTAssertFalse(layout.split(a, edge: .right, with: a))
        XCTAssertEqual(layout.leaves, [a])
    }

    func testSplitWithVisibleTerminalMovesIt() {
        var layout = threePanes()
        XCTAssertTrue(layout.split(a, edge: .bottom, with: c))
        XCTAssertEqual(layout.leaves, [a, c, b])
        XCTAssertEqual(Set(layout.leaves).count, layout.count)
    }

    func testSplitWhenFullCanStillMoveAVisibleTerminal() {
        var layout = threePanes()
        layout.split(a, edge: .bottom, with: d)
        XCTAssertTrue(layout.split(b, edge: .left, with: d))
        XCTAssertEqual(layout.count, 4)
        XCTAssertEqual(layout.leaves.filter { $0 == d }.count, 1)
    }

    // MARK: remove

    func testRemoveCollapsesParent() {
        var layout = threePanes()
        XCTAssertTrue(layout.remove(b))
        XCTAssertEqual(layout.leaves, [a, c])
        XCTAssertEqual(layout.frames(in: unit)[c], CGRect(x: 50, y: 0, width: 50, height: 100))
    }

    func testRemoveFocusedMovesFocusToHeir() {
        var layout = threePanes()
        layout.focus(b)
        layout.remove(b)
        XCTAssertEqual(layout.focused, c)
        layout.remove(c)
        XCTAssertEqual(layout.focused, a)
        XCTAssertEqual(layout.leaves, [a])
        layout.remove(a)
        XCTAssertTrue(layout.isEmpty)
        XCTAssertNil(layout.focused)
    }

    func testRemoveSecondChildHandsFocusToNearestLeafOfFirst() {
        var layout = single(a)
        layout.split(a, edge: .bottom, with: b)
        layout.split(a, edge: .right, with: c)   // (a | c) / b
        layout.focus(b)
        layout.remove(b)
        XCTAssertEqual(layout.focused, c)
    }

    func testRemoveUnknownFails() {
        var layout = single(a)
        XCTAssertFalse(layout.remove(b))
    }

    // MARK: replace / swap

    func testReplaceHiddenTerminal() {
        var layout = threePanes()
        XCTAssertTrue(layout.replace(b, with: d))
        XCTAssertEqual(layout.leaves, [a, d, c])
        XCTAssertEqual(layout.focused, d)
    }

    func testReplaceWithVisibleTerminalSwaps() {
        var layout = threePanes()
        XCTAssertTrue(layout.replace(a, with: c))
        XCTAssertEqual(layout.leaves, [c, b, a])
        XCTAssertEqual(layout.focused, c)
    }

    func testSwap() {
        var layout = threePanes()
        XCTAssertTrue(layout.swap(a, b))
        XCTAssertEqual(layout.leaves, [b, a, c])
        XCTAssertFalse(layout.swap(a, a))
        XCTAssertFalse(layout.swap(a, e))
    }

    // MARK: ratio

    func testSetRatioClampsAndValidatesPath() {
        var layout = threePanes()
        XCTAssertTrue(layout.setRatio(0.7, at: []))
        XCTAssertEqual(layout.frames(in: unit)[a]?.width ?? 0, 70, accuracy: 0.001)
        XCTAssertTrue(layout.setRatio(0.01, at: [1]))
        XCTAssertEqual(layout.frames(in: unit)[b]?.height ?? 0, 10, accuracy: 0.001)
        XCTAssertFalse(layout.setRatio(0.5, at: [0]))     // a 是叶子
        XCTAssertFalse(layout.setRatio(0.5, at: [1, 1]))
        XCTAssertFalse(layout.setRatio(.nan, at: []))
    }

    func testRatioRangeKeepsMinimumPaneSize() {
        var layout = threePanes()
        layout.split(a, edge: .right, with: d)   // (a | d) | (b / c)
        let size = CGSize(width: 1200, height: 600)
        let min = CGSize(width: 280, height: 160)
        let root = layout.ratioRange(at: [], in: size, minPane: min)
        XCTAssertEqual(root.lowerBound, 560.0 / 1200, accuracy: 0.0001)
        XCTAssertEqual(root.upperBound, 1 - 280.0 / 1200, accuracy: 0.0001)
        let right = layout.ratioRange(at: [1], in: size, minPane: min)
        XCTAssertEqual(right.lowerBound, 160.0 / 600, accuracy: 0.0001)
        XCTAssertEqual(right.upperBound, 1 - 160.0 / 600, accuracy: 0.0001)
    }

    func testRatioRangeWhenTooSmallIsSinglePoint() {
        let layout = threePanes()
        let range = layout.ratioRange(at: [], in: CGSize(width: 400, height: 400), minPane: CGSize(width: 280, height: 160))
        XCTAssertEqual(range.lowerBound, range.upperBound)
    }

    func testCanSplitRespectsSizeAndLimit() {
        let layout = threePanes()
        let size = CGSize(width: 1200, height: 600)
        let min = CGSize(width: 280, height: 160)
        XCTAssertTrue(layout.canSplit(a, edge: .right, in: size, minPane: min))
        XCTAssertTrue(layout.canSplit(b, edge: .right, in: size, minPane: min))
        XCTAssertFalse(layout.canSplit(b, edge: .bottom, in: size, minPane: min))   // 300 高 < 320
        XCTAssertFalse(layout.canSplit(e, edge: .right, in: size, minPane: min))
        var full = layout
        full.split(a, edge: .bottom, with: d)
        XCTAssertFalse(full.canSplit(a, edge: .right, in: size, minPane: min))
    }

    // MARK: 焦点移动

    func testNeighborsByGeometry() {
        let layout = threePanes()   // a | (b / c)
        XCTAssertEqual(layout.neighbor(of: a, toward: .right), b)   // 同样近、同样重叠：取靠上的
        XCTAssertNil(layout.neighbor(of: a, toward: .left))
        XCTAssertNil(layout.neighbor(of: a, toward: .top))
        XCTAssertEqual(layout.neighbor(of: b, toward: .left), a)
        XCTAssertEqual(layout.neighbor(of: b, toward: .bottom), c)
        XCTAssertEqual(layout.neighbor(of: c, toward: .top), b)
        XCTAssertEqual(layout.neighbor(of: c, toward: .left), a)
        XCTAssertNil(layout.neighbor(of: c, toward: .right))
    }

    func testNeighborPrefersLargestOverlap() {
        var layout = threePanes()
        layout.setRatio(0.8, at: [1])      // b 高 80%，c 高 20%
        XCTAssertEqual(layout.neighbor(of: a, toward: .right), b)
        layout.setRatio(0.2, at: [1])
        XCTAssertEqual(layout.neighbor(of: a, toward: .right), c)
    }

    func testNeighborIgnoresPanesWithoutOverlap() {
        var layout = single(a)
        layout.split(a, edge: .bottom, with: b)
        layout.split(a, edge: .right, with: c)   // (a | c) / b
        XCTAssertNil(layout.neighbor(of: b, toward: .right))
        XCTAssertEqual(layout.neighbor(of: b, toward: .top), a)
        XCTAssertEqual(layout.neighbor(of: c, toward: .bottom), b)
    }

    func testMoveFocus() {
        var layout = threePanes()
        XCTAssertEqual(layout.moveFocus(.left), a)
        XCTAssertEqual(layout.focused, a)
        XCTAssertNil(layout.moveFocus(.left))
        XCTAssertEqual(layout.focused, a)
        XCTAssertEqual(layout.moveFocus(.right), b)
        XCTAssertEqual(layout.moveFocus(.bottom), c)
    }

    // MARK: 放大

    func testToggleZoom() {
        var layout = threePanes()
        layout.toggleZoom()
        XCTAssertEqual(layout.zoomed, c)
        layout.focus(a)                        // 放大时选中另一个窗格：放大跟着焦点
        XCTAssertEqual(layout.zoomed, a)
        layout.toggleZoom()
        XCTAssertNil(layout.zoomed)
        layout.toggleZoom(b)
        XCTAssertEqual(layout.focused, b)
        layout.moveFocus(.bottom)
        XCTAssertNil(layout.zoomed)
    }

    func testZoomClearedWhenOnlyOnePaneRemainsOrZoomedRemoved() {
        var layout = threePanes()
        layout.toggleZoom(b)
        layout.remove(b)
        XCTAssertNil(layout.zoomed)
        var two = single(a)
        two.split(a, edge: .right, with: b)
        two.toggleZoom(a)
        two.remove(b)
        XCTAssertNil(two.zoomed)
        var one = single(a)
        one.toggleZoom()
        XCTAssertNil(one.zoomed)
    }

    // MARK: 整理与持久化

    func testNormalizeDropsUnknownAndDuplicateLeaves() {
        let root = PaneNode.split(PaneSplit(axis: .horizontal, ratio: 2,
            first: .leaf(a),
            second: .split(PaneSplit(axis: .vertical, first: .leaf(a), second: .leaf(b)))))
        var layout = PaneLayout(root: root, focused: e, zoomed: e)
        XCTAssertEqual(layout.leaves, [a, b])
        XCTAssertEqual(layout.focused, a)
        XCTAssertNil(layout.zoomed)
        layout.setRatio(0.3, at: [])
        layout.normalize(keeping: [b])
        XCTAssertEqual(layout.leaves, [b])
        XCTAssertEqual(layout.root, .leaf(b))
        XCTAssertEqual(layout.focused, b)
    }

    func testNormalizeClampsRatioAndLimitsPaneCount() {
        let five = [a, b, c, d, e].reversed().dropFirst().reduce(PaneNode.leaf(e)) { node, id in
            .split(PaneSplit(axis: .horizontal, ratio: .infinity, first: .leaf(id), second: node))
        }
        let layout = PaneLayout(root: five)
        XCTAssertEqual(layout.leaves, [a, b, c, d])
        XCTAssertEqual(layout.dividers(in: unit).first?.position ?? 0, 50, accuracy: 0.001)
    }

    func testDividers() {
        var layout = threePanes()
        layout.setRatio(0.25, at: [])
        let dividers = layout.dividers(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(dividers.map(\.path), [[], [1]])
        XCTAssertEqual(dividers[0].axis, .horizontal)
        XCTAssertEqual(dividers[0].position, 50, accuracy: 0.001)
        XCTAssertEqual(dividers[1].axis, .vertical)
        XCTAssertEqual(dividers[1].rect, CGRect(x: 50, y: 0, width: 150, height: 100))
        XCTAssertEqual(dividers[1].position, 50, accuracy: 0.001)
    }

    func testCodableRoundTrip() throws {
        var layout = threePanes()
        layout.setRatio(0.3, at: [])
        layout.toggleZoom(b)
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayout.self, from: data), layout)
        XCTAssertEqual(try JSONDecoder().decode(PaneLayout.self, from: try JSONEncoder().encode(PaneLayout())), PaneLayout())
    }

    func testDecodingBrokenTreeGivesEmptyLayout() throws {
        let json = #"{"root": {"axis": "diagonal"}, "focused": "\#(a.uuidString)"}"#
        let layout = try JSONDecoder().decode(PaneLayout.self, from: Data(json.utf8))
        XCTAssertTrue(layout.isEmpty)
        XCTAssertNil(layout.focused)
    }

    func testWorkspaceFileCarriesOptionalLayout() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = WorkspaceFile(entries: [WorkspaceEntry(terminalID: a, cwd: "/a", sessionID: nil, name: "a")],
                                 layout: threePanes())
        try WorkspaceStore.save(file, to: url)
        XCTAssertEqual(WorkspaceStore.load(from: url), file)
        let old = #"{"version": 1, "entries": []}"#
        XCTAssertNil(try JSONDecoder().decode(WorkspaceFile.self, from: Data(old.utf8)).layout)
    }
}
