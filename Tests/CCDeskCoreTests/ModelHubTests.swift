import XCTest
@testable import CCDeskCore

final class ModelHubTests: ZhHansTestCase {
    func testAutoPrefersOfficialAndFallsBackToMirror() {
        var probed: [String] = []
        XCTAssertEqual(ModelHub.choose(source: .auto) { probed.append($0); return true }, ModelHub.official)
        XCTAssertEqual(probed, [ModelHub.official], "官方能连上时不再试镜像")
        XCTAssertEqual(ModelHub.choose(source: .auto) { $0 == ModelHub.mirror }, ModelHub.mirror)
        XCTAssertNil(ModelHub.choose(source: .auto) { _ in false })
    }

    func testExplicitSourcesOnlyProbeThemselves() {
        XCTAssertEqual(ModelHub.choose(source: .mirror) { $0 == ModelHub.mirror }, ModelHub.mirror)
        XCTAssertNil(ModelHub.choose(source: .mirror) { $0 == ModelHub.official })
        XCTAssertNil(ModelHub.choose(source: .official) { $0 == ModelHub.mirror })
    }

    func testMirrorAlsoSwitchesPythonSources() {
        XCTAssertEqual(ModelHub.environment(endpoint: ModelHub.official), ["HF_ENDPOINT": ModelHub.official])
        let env = ModelHub.environment(endpoint: ModelHub.mirror)
        XCTAssertEqual(env["HF_ENDPOINT"], ModelHub.mirror)
        XCTAssertEqual(env["UV_DEFAULT_INDEX"], ModelHub.pypiMirror)
        XCTAssertNotNil(env["UV_PYTHON_INSTALL_MIRROR"])
    }

    func testNaturalVoiceChecksChipBeforeUV() {
        XCTAssertEqual(VoiceSupport.naturalVoiceProblem(appleSilicon: false, hasUV: false), .naturalVoiceNeedsAppleSilicon)
        XCTAssertEqual(VoiceSupport.naturalVoiceProblem(appleSilicon: true, hasUV: false), .naturalVoiceNeedsUV)
        XCTAssertNil(VoiceSupport.naturalVoiceProblem(appleSilicon: true, hasUV: true))
        XCTAssertTrue(VoiceSupport.Problem.naturalVoiceNeedsAppleSilicon.message.contains("Apple 芯片"))
    }
}
