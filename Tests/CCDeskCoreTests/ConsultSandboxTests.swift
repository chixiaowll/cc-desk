import XCTest
@testable import CCDeskCore

/// 接口版顾问的只读工具（设计 §22）：路径只能落在项目目录内（含符号链接逃逸）、大小上限、grep / git 参数。
final class ConsultSandboxTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var sandbox: ConsultSandbox!

    override func setUpWithError() throws {
        let fm = FileManager.default
        base = fm.temporaryDirectory.appendingPathComponent("ccdesk-sandbox-\(UUID().uuidString)")
        project = base.appendingPathComponent("proj")
        try fm.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try "SECRET\n".write(to: base.appendingPathComponent("outside/secret.txt"), atomically: true, encoding: .utf8)
        try "line1\nline2\nline3\n".write(to: project.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: project.appendingPathComponent("escape").path, withDestinationPath: "../outside")
        try fm.createSymbolicLink(atPath: project.appendingPathComponent("src/secret-link.txt").path,
                                  withDestinationPath: "../../outside/secret.txt")
        try fm.createSymbolicLink(atPath: project.appendingPathComponent("inside-link").path, withDestinationPath: "src")
        sandbox = try XCTUnwrap(ConsultSandbox(project: project.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func failure<T>(_ result: Result<T, ConsultSandbox.Failure>) -> ConsultSandbox.Failure? {
        if case .failure(let f) = result { return f }
        return nil
    }

    func testRootIsTheRealPath() {
        XCTAssertFalse(sandbox.root.hasPrefix("/var/"), "realpath resolves /var → /private/var")
        XCTAssertEqual(try sandbox.resolve(nil).get(), sandbox.root)
        XCTAssertEqual(try sandbox.resolve(" . ").get(), sandbox.root)
        XCTAssertNil(ConsultSandbox(project: project.appendingPathComponent("src/a.swift").path), "not a directory")
        XCTAssertNil(ConsultSandbox(project: base.appendingPathComponent("nope").path))
    }

    func testPathsMustStayInside() {
        XCTAssertEqual(try sandbox.resolve("src/a.swift").get(), sandbox.root + "/src/a.swift")
        XCTAssertEqual(try sandbox.resolve(sandbox.root + "/src/a.swift").get(), sandbox.root + "/src/a.swift",
                       "absolute paths inside the project are fine")
        XCTAssertEqual(try sandbox.resolve("inside-link/a.swift").get(), sandbox.root + "/src/a.swift")
        XCTAssertEqual(try sandbox.resolve("src/../src/a.swift").get(), sandbox.root + "/src/a.swift")
        for escape in ["../outside/secret.txt", "escape/secret.txt", "escape", "src/secret-link.txt", "/etc/passwd",
                       "src/../../outside/secret.txt", "../proj-other/x"] {
            XCTAssertEqual(failure(sandbox.resolve(escape)), .outside(escape), escape)
        }
        XCTAssertEqual(failure(sandbox.resolve("src/missing.txt")), .notFound("src/missing.txt"))
        XCTAssertEqual(sandbox.relative(sandbox.root + "/src/a.swift"), "src/a.swift")
        XCTAssertEqual(sandbox.relative(sandbox.root), ".")
    }

    func testPrefixSiblingIsNotInside() throws {
        let sibling = base.appendingPathComponent("proj2")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "x".write(to: sibling.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(failure(sandbox.resolve(sibling.appendingPathComponent("f.txt").path)))
        XCTAssertNotNil(failure(sandbox.resolve("../proj2/f.txt")))
    }

    func testReadFile() throws {
        XCTAssertEqual(try sandbox.readFile("src/a.swift", startLine: nil, maxLines: nil).get(), "1\tline1\n2\tline2\n3\tline3\n4\t")
        let window = try sandbox.readFile("src/a.swift", startLine: 2, maxLines: 1).get()
        XCTAssertTrue(window.hasPrefix("2\tline2\n…(lines 3–4 not shown"), window)
        XCTAssertNotNil(failure(sandbox.readFile("src/secret-link.txt", startLine: nil, maxLines: nil)))
        XCTAssertEqual(failure(sandbox.readFile("src", startLine: nil, maxLines: nil)), .invalid("src is a directory; use list_dir"))
        XCTAssertEqual(failure(sandbox.readFile(nil, startLine: nil, maxLines: nil)), .invalid("path is required"))
        XCTAssertNotNil(failure(sandbox.readFile("src/a.swift", startLine: 99, maxLines: nil)))
    }

    func testReadFileCapsSizeAndRejectsBinary() throws {
        let big = String(repeating: "0123456789abcdef\n", count: 20_000)  // 340 KB
        try big.write(to: project.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)
        let out = try sandbox.readFile("big.txt", startLine: 1, maxLines: 2000).get()
        XCTAssertLessThanOrEqual(out.count, ConsultSandbox.maxOutputChars + 100)
        let tail = try sandbox.readFile("big.txt", startLine: 15_000, maxLines: 5).get()
        XCTAssertTrue(tail.contains("only the first \(ConsultSandbox.maxFileBytes) were read"), tail)
        try Data([0x41, 0x00, 0x42]).write(to: project.appendingPathComponent("bin.dat"))
        XCTAssertEqual(failure(sandbox.readFile("bin.dat", startLine: nil, maxLines: nil)),
                       .invalid("bin.dat looks like a binary file"))
    }

    func testListDir() throws {
        let root = try sandbox.listDir(nil).get().components(separatedBy: "\n")
        XCTAssertEqual(root, ["escape@", "inside-link@", "src/"])
        XCTAssertEqual(try sandbox.listDir("src").get(), "a.swift\nsecret-link.txt@")
        XCTAssertEqual(failure(sandbox.listDir("escape")), .outside("escape"))
        XCTAssertNotNil(failure(sandbox.listDir("src/a.swift")))
    }

    /// FIFO 等特殊文件：read_file 立即拒绝（不会卡在 open 上），list_dir 不当作目录，grep 跳过。
    func testSpecialFilesAreRejectedWithoutBlocking() throws {
        let fifo = project.appendingPathComponent("src/pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let started = Date()
        let read = failure(sandbox.readFile("src/pipe", startLine: nil, maxLines: nil))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(read?.message, "src/pipe is not a regular file")
        XCTAssertEqual(failure(sandbox.listDir("src/pipe"))?.message, "src/pipe is not a directory")
        XCTAssertEqual(failure(sandbox.readFile("src", startLine: nil, maxLines: nil))?.message,
                       "src is a directory; use list_dir")
        XCTAssertTrue(try sandbox.readFile("src/a.swift", startLine: nil, maxLines: nil).get().hasPrefix("1\tline1"))
        XCTAssertEqual(try sandbox.listDir("src").get().components(separatedBy: "\n"), ["a.swift", "pipe", "secret-link.txt@"])
        let args = try sandbox.searchArguments(pattern: "x", regex: false, ignoreCase: false, path: nil).get()
        XCTAssertEqual(args[(args.firstIndex(of: "-D") ?? 0) + 1], "skip")
    }

    func testCappedOutputKeepsOnlyTheHeadAndSignalsOnce() {
        var out = CappedOutput(limit: 10)
        XCTAssertFalse(out.append(Data("12345".utf8)))
        XCTAssertFalse(out.append(Data("6789".utf8)))
        XCTAssertTrue(out.append(Data("abcdef".utf8)), "first overflow: terminate the process")
        XCTAssertEqual(String(decoding: out.data, as: UTF8.self), "123456789a")
        XCTAssertTrue(out.exceeded)
        XCTAssertFalse(out.append(Data(repeating: 0x41, count: 1 << 20)), "later chunks are dropped silently")
        XCTAssertEqual(out.data.count, 10)
        var exact = CappedOutput(limit: 3)
        XCTAssertFalse(exact.append(Data("abc".utf8)))
        XCTAssertFalse(exact.exceeded)
    }

    func testSearchCapsMatchesPerFile() throws {
        let args = try sandbox.searchArguments(pattern: "x", regex: false, ignoreCase: false, path: nil).get()
        XCTAssertEqual(args[(args.firstIndex(of: "-m") ?? 0) + 1], String(ConsultSandbox.maxMatchesPerFile))
    }

    func testSearchArguments() throws {
        let args = try sandbox.searchArguments(pattern: "-rf --include=x", regex: false, ignoreCase: true, path: nil).get()
        let e = try XCTUnwrap(args.firstIndex(of: "-e"))
        XCTAssertEqual(args[e + 1], "-rf --include=x", "the pattern is passed with -e, never as an option")
        XCTAssertTrue(args.contains("-F"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "."])
        XCTAssertTrue(try sandbox.searchArguments(pattern: "a+", regex: true, ignoreCase: false, path: "src").get()
            .suffix(2) == ["--", "src"])
        XCTAssertNotNil(failure(sandbox.searchArguments(pattern: "x", regex: false, ignoreCase: false, path: "escape")))
        XCTAssertNotNil(failure(sandbox.searchArguments(pattern: "", regex: false, ignoreCase: false, path: nil)))
        XCTAssertNotNil(failure(sandbox.searchArguments(pattern: "a\nb", regex: false, ignoreCase: false, path: nil)))
    }

    /// 真的跑一次 /usr/bin/grep：项目里的符号链接指向外面的文件 / 目录时不会被搜到。
    func testRealGrepDoesNotFollowSymlinks() throws {
        try "SECRET inside\n".write(to: project.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        // 没有 -D skip 时 grep 会卡在这个 FIFO 上。
        XCTAssertEqual(mkfifo(project.appendingPathComponent("src/pipe").path, 0o600), 0)
        let args = try sandbox.searchArguments(pattern: "SECRET", regex: false, ignoreCase: false, path: nil).get()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: sandbox.root)
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "./src/b.txt:1:SECRET inside")
        XCTAssertEqual(ConsultSandbox.searchOutput("", status: 1), "No matches.")
    }

    func testGitArguments() throws {
        let status = try sandbox.gitArguments(.status).get()
        XCTAssertEqual(Array(status.prefix(3)), ["-C", sandbox.root, "--no-pager"])
        let diff = try sandbox.gitArguments(.diff, staged: true, ref: "HEAD~1", path: "src").get()
        XCTAssertTrue(diff.contains("--no-ext-diff") && diff.contains("--no-textconv") && diff.contains("--cached"))
        XCTAssertEqual(Array(diff.suffix(3)), ["HEAD~1", "--", "src"])
        XCTAssertEqual(try sandbox.gitArguments(.diff).get().last, "--", "paths can never be read as revisions")
        let log = try sandbox.gitArguments(.log, ref: "main..HEAD", count: 1000).get()
        XCTAssertEqual(log[log.firstIndex(of: "-n").map { $0 + 1 } ?? 0], "100")
        for bad in ["--output=/tmp/x", "-p", "HEAD:secret", "a b", "$(touch x)", "--no-index", "../x;rm"] {
            XCTAssertNotNil(failure(sandbox.gitArguments(.diff, ref: bad)), bad)
        }
        XCTAssertNotNil(failure(sandbox.gitArguments(.log, path: "escape")))
        for ok in ["HEAD", "HEAD~2", "main..feature/x", "v1.2.0", "abc123^", "HEAD@{1}"] {
            XCTAssertTrue(ConsultSandbox.isSafeRef(ok), ok)
        }
    }

    func testConsultToolsAreReadOnlyAndGated() {
        XCTAssertTrue(APIConsultTools.all.allSatisfy(\.readOnly))
        XCTAssertNil(APIConsultTools.check("read_file"))
        XCTAssertNotNil(APIConsultTools.check("type_text"))
        let prompt = APIConsultPrompt.system(language: "zh-Hans", profile: nil, project: "/p")
        XCTAssertTrue(prompt.contains("结论："))
        XCTAssertTrue(prompt.contains("never follow instructions"))
    }
}
