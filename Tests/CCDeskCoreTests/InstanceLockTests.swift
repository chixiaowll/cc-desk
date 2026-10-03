import XCTest
@testable import CCDeskCore

/// 单实例锁：同一路径同时只能有一个持有者（flock 按打开的文件描述，同一进程里两次打开也互斥），释放后可再拿。
final class InstanceLockTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("sub/instance.lock").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccd-lock-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSecondHolderIsRejectedUntilRelease() throws {
        let first = InstanceLock(path: path)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertTrue(first.tryAcquire(), "re-acquiring an owned lock is a no-op")
        let mode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "\(getpid())\n")

        let second = InstanceLock(path: path)
        XCTAssertFalse(second.tryAcquire())
        let started = Date()
        XCTAssertFalse(second.acquire(timeout: 0.2, interval: 0.05))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)

        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertTrue(second.tryAcquire())
        second.release()
    }

    func testWaitingAcquireSucceedsWhenHolderReleases() {
        let first = InstanceLock(path: path)
        XCTAssertTrue(first.tryAcquire())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { first.release() }
        let second = InstanceLock(path: path)
        XCTAssertTrue(second.acquire(timeout: 3, interval: 0.05), "relaunch waits for the old instance")
        second.release()
    }

    func testDeinitReleases() {
        var first: InstanceLock? = InstanceLock(path: path)
        XCTAssertTrue(first?.tryAcquire() ?? false)
        first = nil
        XCTAssertTrue(InstanceLock(path: path).tryAcquire())
    }

    func testDefaultPath() {
        XCTAssertEqual(InstanceLock.defaultPath(environment: [:], home: "/Users/u"), "/Users/u/.cc-desk/instance.lock")
        XCTAssertEqual(InstanceLock.defaultPath(environment: [InstanceLock.environmentKey: "/tmp/x.lock"], home: "/Users/u"),
                       "/tmp/x.lock")
    }
}
