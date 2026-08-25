import XCTest
@testable import Doubao_Murmur

final class PasteRouterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.doubao.murmur.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testExactUUBundleUsesCompatibilityByDefault() {
        let router = PasteRouter(settings: PasteRoutingSettings(defaults: defaults))

        XCTAssertEqual(router.route(bundleIdentifier: "com.netease.uuremote"), .uuCompatibility)
    }

    func testOtherBundleIdentifiersAlwaysUseLocalRoute() {
        let router = PasteRouter(settings: PasteRoutingSettings(defaults: defaults))

        XCTAssertEqual(router.route(bundleIdentifier: "com.netease.uuremote.beta"), .local)
        XCTAssertEqual(router.route(bundleIdentifier: "com.example.editor"), .local)
        XCTAssertEqual(router.route(bundleIdentifier: nil), .local)
    }

    func testDirectModePersistsWithoutChangingQuietPeriod() {
        defaults.set(0.5, forKey: PasteHelper.quietPeriodDefaultsKey)
        let settings = PasteRoutingSettings(defaults: defaults)
        XCTAssertEqual(settings.uuPasteMode, .compatibility)

        settings.uuPasteMode = .direct
        XCTAssertEqual(PasteRoutingSettings(defaults: defaults).uuPasteMode, .direct)
        XCTAssertEqual(defaults.double(forKey: PasteHelper.quietPeriodDefaultsKey), 0.5, accuracy: 0.0001)
    }

    func testRouteDispatchInvokesOnlyItsSelectedStrategy() {
        for route in [PasteRoute.local, .uuCompatibility, .uuDirect] {
            var calls: [PasteRoute] = []
            PasteRouter.execute(
                route,
                local: { calls.append(.local) },
                uuCompatibility: { calls.append(.uuCompatibility) },
                uuDirect: { calls.append(.uuDirect) }
            )
            XCTAssertEqual(calls, [route])
        }
    }

    func testRemoteRoutesPrepublishClipboardWithoutAuthorizingPaste() {
        XCTAssertFalse(PasteRouter.shouldPrepublishLocalClipboard(for: .local))
        XCTAssertTrue(PasteRouter.shouldPrepublishLocalClipboard(for: .uuCompatibility))
        XCTAssertTrue(PasteRouter.shouldPrepublishLocalClipboard(for: .uuDirect))
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .remoteWriteFailed).shouldPaste)
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .targetUnavailableBeforeRequest).shouldPaste)
    }

    func testDirectWriteFailureCopiesTextPresentsExactPromptAndNeverPastesOrDowngrades() {
        let settings = PasteRoutingSettings(defaults: defaults)
        settings.uuPasteMode = .direct
        let handler = DirectPasteFailureHandler(settings: settings)
        var copiedTexts: [String] = []
        var presentedPrompts: [RemoteClipboardFailurePrompt] = []

        handler.handle(
            outcome: .remoteWriteFailed,
            text: "test transcription",
            copyTextLocally: { copiedTexts.append($0) },
            present: { prompt, _ in presentedPrompts.append(prompt) }
        )

        XCTAssertEqual(copiedTexts, ["test transcription"])
        XCTAssertEqual(presentedPrompts, [.writeFailure])
        XCTAssertEqual(RemoteClipboardFailurePrompt.writeFailure.title, "被控制端剪贴板写入失败")
        XCTAssertEqual(RemoteClipboardFailurePrompt.writeFailure.message, "请检查被控制端助手和 UU 端口映射，或切换到兼容模式。")
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .remoteWriteFailed).shouldPaste)
        XCTAssertEqual(settings.uuPasteMode, .direct)
    }

    func testSelectingCompatibilityOnlyChangesFutureModeInIsolatedDefaults() {
        defaults.set(0.5, forKey: PasteHelper.quietPeriodDefaultsKey)
        let settings = PasteRoutingSettings(defaults: defaults)
        settings.uuPasteMode = .direct
        let handler = DirectPasteFailureHandler(settings: settings)
        var switchToCompatibility: (() -> Void)?

        handler.handle(
            outcome: .remoteWriteFailed,
            text: "test transcription",
            copyTextLocally: { _ in },
            present: { _, action in switchToCompatibility = action }
        )
        XCTAssertEqual(settings.uuPasteMode, .direct)

        switchToCompatibility?()
        XCTAssertEqual(settings.uuPasteMode, .compatibility)
        XCTAssertEqual(defaults.double(forKey: PasteHelper.quietPeriodDefaultsKey), 0.5, accuracy: 0.0001)
    }

    func testCancelledOrStaleOutcomeHasNoEffects() {
        var copiedTexts: [String] = []
        var presentedPrompts: [RemoteClipboardFailurePrompt] = []
        let handler = DirectPasteFailureHandler(settings: PasteRoutingSettings(defaults: defaults))

        handler.handle(
            outcome: .cancelledOrStale,
            text: "test transcription",
            copyTextLocally: { copiedTexts.append($0) },
            present: { prompt, _ in presentedPrompts.append(prompt) }
        )

        XCTAssertTrue(copiedTexts.isEmpty)
        XCTAssertTrue(presentedPrompts.isEmpty)
        XCTAssertEqual(
            DirectPasteFailureHandler.plan(for: .cancelledOrStale),
            DirectPasteFailurePlan(shouldCopyLocally: false, shouldPresentWriteFailure: false, shouldPaste: false)
        )
    }

    func testFocusChangeAfterAcknowledgementIsNotClassifiedAsWriteFailure() {
        var copiedTexts: [String] = []
        var presentedPrompts: [RemoteClipboardFailurePrompt] = []
        let handler = DirectPasteFailureHandler(settings: PasteRoutingSettings(defaults: defaults))

        handler.handle(
            outcome: .targetFocusChangedAfterAcknowledgement,
            text: "test transcription",
            copyTextLocally: { copiedTexts.append($0) },
            present: { prompt, _ in presentedPrompts.append(prompt) }
        )

        XCTAssertEqual(copiedTexts, ["test transcription"])
        XCTAssertTrue(presentedPrompts.isEmpty)
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .targetFocusChangedAfterAcknowledgement).shouldPresentWriteFailure)
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .targetFocusChangedAfterAcknowledgement).shouldPaste)
    }

    func testUnavailableTargetBeforeDirectRequestSavesTextWithoutPromptPasteOrModeChange() {
        let settings = PasteRoutingSettings(defaults: defaults)
        settings.uuPasteMode = .direct
        let handler = DirectPasteFailureHandler(settings: settings)
        var copiedTexts: [String] = []
        var presentedPrompts: [RemoteClipboardFailurePrompt] = []

        handler.handle(
            outcome: .targetUnavailableBeforeRequest,
            text: "test transcription",
            copyTextLocally: { copiedTexts.append($0) },
            present: { prompt, _ in presentedPrompts.append(prompt) }
        )

        XCTAssertEqual(copiedTexts, ["test transcription"])
        XCTAssertTrue(presentedPrompts.isEmpty)
        XCTAssertEqual(settings.uuPasteMode, .direct)
        XCTAssertEqual(
            DirectPasteFailureHandler.plan(for: .targetUnavailableBeforeRequest),
            DirectPasteFailurePlan(shouldCopyLocally: true, shouldPresentWriteFailure: false, shouldPaste: false)
        )
    }
}
