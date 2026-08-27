import Foundation
import XCTest
@testable import Doubao_Murmur

final class UpdateCheckerTests: XCTestCase {
    func testUsesCurrentIndependentRepositoryAndExpectedAppAssetName() {
        let update = UpdateChecker.UpdateInfo(
            version: "1.3.0",
            tag: "v1.3.0",
            downloadURL: URL(string: "https://github.com/devon-kong/doubao-murmur/releases/tag/v1.3.0")!
        )

        XCTAssertEqual(UpdateChecker.repository, "devon-kong/doubao-murmur")
        XCTAssertEqual(
            update.assetURL.absoluteString,
            "https://github.com/devon-kong/doubao-murmur/releases/download/v1.3.0/Doubao-Murmur-v1.3.0.zip"
        )
    }

    func testVersionComparisonTreatsMissingComponentsAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.3.0", current: "1.2.9"))
        XCTAssertTrue(UpdateChecker.isNewer(remote: "1.3.1", current: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.3.0", current: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(remote: "1.2.9", current: "1.3.0"))
    }
}

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
        super.tearDown()
    }
    func testExactUUBundleUsesCompatibilityByDefault() {
        let router = PasteRouter(settings: PasteRoutingSettings(defaults: defaults))

        XCTAssertEqual(router.route(bundleIdentifier: PasteRouter.uuBundleIdentifier), .uuCompatibility)
    }

    func testOtherBundleIdentifiersAlwaysUseLocalRoute() {
        let router = PasteRouter(settings: PasteRoutingSettings(defaults: defaults))

        XCTAssertEqual(router.route(bundleIdentifier: "com.netease.uuremote.beta"), .local)
        XCTAssertEqual(router.route(bundleIdentifier: "com.example.editor"), .local)
        XCTAssertEqual(router.route(bundleIdentifier: nil), .local)
    }

    func testOnlyCompatibilityRoutePrepublishesControllerClipboard() {
        XCTAssertFalse(PasteRouter.shouldPrepublishLocalClipboard(for: .local))
        XCTAssertTrue(PasteRouter.shouldPrepublishLocalClipboard(for: .uuCompatibility))
        XCTAssertFalse(PasteRouter.shouldPrepublishLocalClipboard(for: .uuDirect))
    }
    func testDirectModePersistsWithoutChangingCompatibilityDelay() {
        defaults.set(0.5, forKey: PasteHelper.quietPeriodDefaultsKey)
        let settings = PasteRoutingSettings(defaults: defaults)
        settings.uuPasteMode = .direct
        XCTAssertEqual(PasteRoutingSettings(defaults: defaults).uuPasteMode, .direct)
        XCTAssertEqual(defaults.double(forKey: PasteHelper.quietPeriodDefaultsKey), 0.5, accuracy: 0.0001)
    }
    func testRouteDispatchInvokesOnlySelectedStrategy() {
        for route in [PasteRoute.local, .uuCompatibility, .uuDirect] {
            var calls: [PasteRoute] = []
            PasteRouter.execute(route, local: { calls.append(.local) }, uuCompatibility: { calls.append(.uuCompatibility) }, uuDirect: { calls.append(.uuDirect) })
            XCTAssertEqual(calls, [route])
        }
    }
    func testCompatibilityMaximumWaitAllowsTwoStableWindowsWithTwoSecondFloor() {
        XCTAssertEqual(PasteHelper.ClipboardDefensePolicy.maximumWait(for: 0.25), 2.0, accuracy: 0.0001)
        XCTAssertEqual(PasteHelper.ClipboardDefensePolicy.maximumWait(for: 1.0), 2.0, accuracy: 0.0001)
        XCTAssertEqual(PasteHelper.ClipboardDefensePolicy.maximumWait(for: 2.0), 4.0, accuracy: 0.0001)
        XCTAssertEqual(PasteHelper.ClipboardDefensePolicy.maximumWait(for: 2.5), 5.0, accuracy: 0.0001)
    }

    func testCompatibilityStopsAsSoonAsRemainingBudgetCannotCompleteStableWindow() {
        XCTAssertTrue(
            PasteHelper.ClipboardDefensePolicy.canStillSucceed(
                stableElapsed: 0,
                remainingBudget: 2.3,
                stableWindow: 2.0
            )
        )
        XCTAssertFalse(
            PasteHelper.ClipboardDefensePolicy.canStillSucceed(
                stableElapsed: 0,
                remainingBudget: 1.8,
                stableWindow: 2.0
            )
        )
        XCTAssertTrue(
            PasteHelper.ClipboardDefensePolicy.canStillSucceed(
                stableElapsed: 1.5,
                remainingBudget: 0.5,
                stableWindow: 2.0
            )
        )
    }

    func testCompatibilityLateTickFailsAtDeadlineBeforeClipboardDefense() {
        let deadline = 100.0
        for now in [deadline, deadline + 0.001] {
            XCTAssertEqual(
                PasteHelper.ClipboardDefensePolicy.decision(
                    phase: .defendingClipboard,
                    now: now,
                    deadline: deadline,
                    targetIsFrontmost: true,
                    clipboardMatches: true
                ),
                .deadlineExpired,
                "A late scheduled tick must not reach clipboard defense or Command-V"
            )
        }
    }

    func testCompatibilityInitialUnrestoredTargetFailsBeforeStartingDefense() {
        XCTAssertEqual(
            PasteHelper.ClipboardDefensePolicy.initialTargetDecision(targetIsFrontmost: false),
            .targetNotFrontmost
        )
    }

    func testCompatibilityTargetSwitchDuringWaitFailsInDefendingPhase() {
        XCTAssertEqual(
            PasteHelper.ClipboardDefensePolicy.decision(
                phase: .defendingClipboard,
                now: 99.9,
                deadline: 100.0,
                targetIsFrontmost: false,
                clipboardMatches: true
            ),
            .targetNotFrontmost
        )
    }

    func testCompatibilityTargetSwitchBeforeEventFailsFinalAuthorization() {
        XCTAssertEqual(
            PasteHelper.ClipboardDefensePolicy.decision(
                phase: .finalEventAuthorization,
                now: 99.9,
                deadline: 100.0,
                targetIsFrontmost: false,
                clipboardMatches: true
            ),
            .targetNotFrontmost
        )
    }

    func testCompatibilityHealthyFinalAuthorizationPostsExactlyOneEvent() {
        let decision = PasteHelper.ClipboardDefensePolicy.decision(
            phase: .finalEventAuthorization,
            now: 99.9,
            deadline: 100.0,
            targetIsFrontmost: true,
            clipboardMatches: true
        )
        let postedEventCount = decision == .postPasteEvent ? 1 : 0
        XCTAssertEqual(postedEventCount, 1)
    }

    func testCompatibilityChangedClipboardResetsStableWindowInsteadOfPosting() {
        XCTAssertEqual(
            PasteHelper.ClipboardDefensePolicy.decision(
                phase: .finalEventAuthorization,
                now: 99.9,
                deadline: 100.0,
                targetIsFrontmost: true,
                clipboardMatches: false
            ),
            .resetStableWindow
        )
    }
}

final class RecordingReadinessGateTests: XCTestCase {
    func testAllThreeReadinessConditionsAuthorizeExactlyOneRightCommandStart() {
        var focusFirst = RecordingReadinessGate()
        let focusFirstActions = [
            focusFirst.markFocusReady(),
            focusFirst.markInputSourceReady(),
            focusFirst.markHotkeyReleased(),
            focusFirst.markFocusReady(),
            focusFirst.markInputSourceReady(),
            focusFirst.markHotkeyReleased()
        ]
        XCTAssertEqual(focusFirstActions.filter { $0 == .postRightCommandStart }.count, 1)

        var inputSourceFirst = RecordingReadinessGate()
        let inputSourceFirstActions = [
            inputSourceFirst.markInputSourceReady(),
            inputSourceFirst.markFocusReady(),
            inputSourceFirst.markHotkeyReleased(),
            inputSourceFirst.markInputSourceReady(),
            inputSourceFirst.markFocusReady(),
            inputSourceFirst.markHotkeyReleased()
        ]
        XCTAssertEqual(inputSourceFirstActions.filter { $0 == .postRightCommandStart }.count, 1)
    }

    func testCancellationRejectsLateReadinessCallbacks() {
        var gate = RecordingReadinessGate()
        XCTAssertEqual(gate.markFocusReady(), .none)
        gate.cancel()
        XCTAssertEqual(gate.markInputSourceReady(), .none)
        XCTAssertEqual(gate.markFocusReady(), .none)
        XCTAssertEqual(gate.markHotkeyReleased(), .none)
    }
}

final class StopHotkeyReleaseGateTests: XCTestCase {
    func testSlashThenControlReleaseTriggersExactlyOnce() {
        var gate = StopHotkeyReleaseGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertEqual(gate.observeSlashRelease(), [.slashReleased])
        XCTAssertEqual(gate.observeControlRelease(), [.controlReleased, .fullyReleased])
        XCTAssertEqual(gate.observeControlRelease(), [])
        XCTAssertEqual(gate.observeSlashRelease(), [])
    }

    func testControlThenSlashReleaseTriggersExactlyOnce() {
        var gate = StopHotkeyReleaseGate()

        XCTAssertTrue(gate.begin())
        XCTAssertEqual(gate.observeControlRelease(), [.controlReleased])
        XCTAssertEqual(gate.observeSlashRelease(), [.slashReleased, .fullyReleased])
    }

    func testPartialAndRepeatedEventsNeverAuthorizeStop() {
        var gate = StopHotkeyReleaseGate()

        XCTAssertTrue(gate.begin())
        XCTAssertEqual(gate.observeSlashRelease(), [.slashReleased])
        XCTAssertEqual(gate.observeSlashRelease(), [])
        gate.cancel()
        XCTAssertEqual(gate.observeControlRelease(), [])
        XCTAssertEqual(gate.observeSlashRelease(), [])
    }
}

final class MarkedTextCommitGateTests: XCTestCase {
    func testTextInputFocusStatusRequiresKeyWindowAndTextViewFirstResponder() {
        XCTAssertEqual(
            TextInputFocusStatus.evaluate(
                panelIsKeyWindow: false,
                textViewIsAvailable: true,
                textViewIsFirstResponder: true
            ),
            .panelNotKey
        )
        XCTAssertEqual(
            TextInputFocusStatus.evaluate(
                panelIsKeyWindow: true,
                textViewIsAvailable: true,
                textViewIsFirstResponder: false
            ),
            .textViewNotFirstResponder
        )
        XCTAssertEqual(
            TextInputFocusStatus.evaluate(
                panelIsKeyWindow: true,
                textViewIsAvailable: true,
                textViewIsFirstResponder: true
            ),
            .confirmed
        )
    }

    func testMarkedTextMustTransitionFromTrueToFalseWhileStoppingBeforeCompletion() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: false), .none)
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.observe(hasMarkedText: true), .none)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .markedTextCommitted)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .none)
    }

    func testFalseBeforeCommitDoesNotAuthorizeFreezeOrHide() {
        var gate = MarkedTextCommitGate()
        var freezeCount = 0
        var hideCount = 0
        for action in [
            gate.observe(hasMarkedText: false),
            gate.beginStopping(currentlyHasMarkedText: false),
            gate.observe(hasMarkedText: false)
        ] where action == .markedTextCommitted {
            freezeCount += 1
            hideCount += 1
        }
        XCTAssertEqual(freezeCount, 0)
        XCTAssertEqual(hideCount, 0)
    }

    func testSameStringStillCompletesWhenOnlyMarkedStateDisappears() {
        let textBeforeCommit = "字符串未变化"
        let textAfterCommit = "字符串未变化"
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: true), .none)
        XCTAssertEqual(textAfterCommit, textBeforeCommit)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .markedTextCommitted)
    }

    func testCommitAlreadyObservedBeforeFnUpCompletesAtStoppingQuery() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .none)
        XCTAssertEqual(
            gate.beginStopping(currentlyHasMarkedText: false),
            .markedTextCommitted
        )
    }

    func testFocusLostAfterFnUpCancelsInsteadOfAuthorizingTextFreeze() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: true), .none)
        XCTAssertEqual(gate.observeFocus(isConfirmed: false), .focusLost)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .none)
    }

    func testFocusLostAfterMarkedTextCommitButBeforeFinalLockStillCancels() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: true), .none)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .markedTextCommitted)
        XCTAssertEqual(gate.observeFocus(isConfirmed: false), .focusLost)
    }

    func testProgrammaticCleanupCannotCreateCommit() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: true), .none)
        gate.cancel()
        XCTAssertEqual(gate.observe(hasMarkedText: false), .none)

        let textView = IMETrackingTextView(frame: .zero)
        var markedStateCallbacks: [Bool] = []
        textView.onMarkedTextStateChanged = { markedStateCallbacks.append($0) }
        textView.string = "cleanup"
        textView.clearProgrammatically()
        XCTAssertTrue(markedStateCallbacks.isEmpty)
    }

    func testNeverCommittedMarkedTextTimesOutWithoutAuthorizingFreezeOrHide() {
        var gate = MarkedTextCommitGate()
        XCTAssertEqual(gate.observe(hasMarkedText: true), .markedTextStarted)
        XCTAssertEqual(gate.beginStopping(currentlyHasMarkedText: true), .none)
        XCTAssertEqual(gate.expireWaitingForCommit(), .timedOut)
        XCTAssertEqual(gate.observe(hasMarkedText: false), .none)
    }

    func testControlSlashDoesNotStopAnActiveRecording() {
        XCTAssertEqual(SessionTogglePolicy.action(for: .stopping), .cancel)
        XCTAssertEqual(SessionTogglePolicy.action(for: .preparing), .cancel)
        XCTAssertEqual(SessionTogglePolicy.action(for: .recording), .ignoreWhileRecording)
        XCTAssertEqual(SessionTogglePolicy.action(for: .idle), .start)
    }
}

final class PhysicalRightCommandStopGateTests: XCTestCase {
    func testPhysicalUpAndMarkedCommitAuthorizeExactlyOnceInEitherOrder() {
        let eventOrders: [[(inout PhysicalRightCommandStopGate) -> PhysicalRightCommandStopGate.Action]] = [
            [
                { $0.observePhysicalRightCommandDown() },
                { $0.markMarkedTextCommitted() },
                { $0.observePhysicalRightCommandUp() }
            ],
            [
                { $0.observePhysicalRightCommandDown() },
                { $0.observePhysicalRightCommandUp() },
                { $0.markMarkedTextCommitted() }
            ]
        ]

        for events in eventOrders {
            var gate = PhysicalRightCommandStopGate()
            let actions = events.map { $0(&gate) }
            XCTAssertEqual(actions.filter { $0 == .scheduleFinalTextLock }.count, 1)
            XCTAssertEqual(gate.markMarkedTextCommitted(), .none)
            XCTAssertEqual(gate.observePhysicalRightCommandUp(), .none)
        }
    }

    func testDuplicateAndPartialCallbacksCannotAuthorizeFinalLock() {
        var gate = PhysicalRightCommandStopGate()
        XCTAssertEqual(gate.observePhysicalRightCommandDown(), .startedStopping)
        XCTAssertEqual(gate.observePhysicalRightCommandDown(), .none)
        XCTAssertEqual(gate.markMarkedTextCommitted(), .none)
        XCTAssertEqual(gate.markMarkedTextCommitted(), .none)
        XCTAssertEqual(gate.observePhysicalRightCommandUp(), .scheduleFinalTextLock)
        XCTAssertEqual(gate.observePhysicalRightCommandUp(), .none)
    }

    func testNonBareRightCommandCancelsAndCannotAuthorizePaste() {
        var gate = PhysicalRightCommandStopGate()
        XCTAssertEqual(gate.observePhysicalRightCommandDown(), .startedStopping)
        XCTAssertEqual(gate.observeOrdinaryKeyDown(), .nonBareCommand)
        XCTAssertEqual(gate.observePhysicalRightCommandUp(), .none)
        XCTAssertEqual(gate.markMarkedTextCommitted(), .none)
    }

    func testCancellationAndTimeoutRejectLateCallbacks() {
        var cancelled = PhysicalRightCommandStopGate()
        XCTAssertEqual(cancelled.observePhysicalRightCommandDown(), .startedStopping)
        cancelled.cancel()
        XCTAssertEqual(cancelled.observePhysicalRightCommandUp(), .none)
        XCTAssertEqual(cancelled.markMarkedTextCommitted(), .none)

        var timedOut = PhysicalRightCommandStopGate()
        XCTAssertEqual(timedOut.observePhysicalRightCommandDown(), .startedStopping)
        XCTAssertEqual(timedOut.expireWaiting(), .timedOut)
        XCTAssertEqual(timedOut.observePhysicalRightCommandUp(), .none)
        XCTAssertEqual(timedOut.markMarkedTextCommitted(), .none)
    }

    func testSyntheticStartAndOtherKeysAreNotPhysicalRightCommandStops() {
        XCTAssertFalse(
            PhysicalRightCommandEventFilter.isPhysicalRightCommand(
                keyCode: 54,
                sourcePID: 12345
            )
        )
        XCTAssertFalse(
            PhysicalRightCommandEventFilter.isPhysicalRightCommand(
                keyCode: 55,
                sourcePID: 0
            )
        )
        XCTAssertTrue(
            PhysicalRightCommandEventFilter.isPhysicalRightCommand(
                keyCode: 54,
                sourcePID: 0
            )
        )
    }

    func testOrdinaryPhysicalKeyFilterRequiresPhysicalKeyDown() {
        XCTAssertTrue(
            PhysicalRightCommandEventFilter.isPhysicalOrdinaryKeyDown(
                type: .keyDown,
                keyCode: 8,
                sourcePID: 0
            )
        )
        XCTAssertFalse(
            PhysicalRightCommandEventFilter.isPhysicalOrdinaryKeyDown(
                type: .keyDown,
                keyCode: 54,
                sourcePID: 0
            )
        )
        XCTAssertFalse(
            PhysicalRightCommandEventFilter.isPhysicalOrdinaryKeyDown(
                type: .keyDown,
                keyCode: 8,
                sourcePID: 12345
            )
        )
    }

    func testMarkedCommitWithoutPhysicalCommandUpCannotAuthorizeFinalLock() {
        var gate = PhysicalRightCommandStopGate()
        XCTAssertEqual(gate.markMarkedTextCommitted(), .none)
        XCTAssertEqual(gate.observePhysicalRightCommandUp(), .none)
    }
}

@MainActor
final class DirectPasteOrderCoordinatorTests: XCTestCase {
    func testDelayedFirstAcknowledgementDoesNotBlockSecondAndReverseACKsMatchOrders() async throws {
        let sender = ControllableOrderSender()
        let coordinator = makeCoordinator(sender: sender)
        let first = submit("001", to: coordinator)
        let second = submit("002", to: coordinator)
        XCTAssertEqual(first.controllerSessionId, second.controllerSessionId)
        XCTAssertEqual(first.sequence + 1, second.sequence)
        try await sender.waitForRequestCount(2)
        XCTAssertEqual(coordinator.activeRequestCount, 2)
        await sender.succeed(second)
        try await waitUntil { coordinator.state(for: second.requestId) == .acknowledgedEventPosted }
        XCTAssertEqual(coordinator.state(for: first.requestId), .sending)
        await sender.succeed(first)
        try await waitUntil { coordinator.state(for: first.requestId) == .acknowledgedEventPosted }
        let firstSendCount = await sender.sendCount(for: first.requestId)
        let secondSendCount = await sender.sendCount(for: second.requestId)
        XCTAssertEqual(firstSendCount, 1)
        XCTAssertEqual(secondSendCount, 1)
    }
    func testOneTimeoutDoesNotPolluteLaterAcknowledgedOrder() async throws {
        let sender = ControllableOrderSender()
        var unknownCounts: [Int] = []
        let coordinator = makeCoordinator(sender: sender, countChanged: { unknownCounts.append($0) })
        let first = submit("001", to: coordinator)
        let second = submit("002", to: coordinator)
        try await sender.waitForRequestCount(2)
        await sender.fail(first, error: URLError(.timedOut))
        await sender.succeed(second)
        try await waitUntil { coordinator.state(for: first.requestId) == .unconfirmed }
        try await waitUntil { coordinator.state(for: second.requestId) == .acknowledgedEventPosted }
        XCTAssertEqual(coordinator.unconfirmedRequestCount, 1)
        XCTAssertTrue(unknownCounts.contains(1))
    }
    func testNewRecordingAndCancellationDoNotCancelSentOrder() async throws {
        let sender = ControllableOrderSender()
        let coordinator = makeCoordinator(sender: sender)
        let sent = submit("sent", to: coordinator)
        try await sender.waitForRequestCount(1)
        let cancelledRecording = coordinator.beginRecording()
        coordinator.abandonRecording(identity: cancelledRecording, reason: .sessionCancelled)
        XCTAssertEqual(coordinator.state(for: sent.requestId), .sending)
        XCTAssertEqual(coordinator.activeRequestCount, 1)
        await sender.succeed(sent)
        try await waitUntil { coordinator.state(for: sent.requestId) == .acknowledgedEventPosted }
    }

    func testAbandonedRecordingsLogOneCancelledTerminalWithSafeReason() throws {
        let logger = PasteOrderEventLogger(
            side: "controller-test",
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-orders-\(UUID().uuidString).sqlite3")
        )
        let coordinator = DirectPasteOrderCoordinator(
            logger: logger,
            sendOperation: { _, _, _ in
                XCTFail("An abandoned recording must not send")
                throw TestWaitError.timeout
            }
        )
        let reasons: [DirectPasteCancellationReason] = [
            .emptyTranscription,
            .sessionCancelled,
            .inputSourceSelectionFailed,
            .routeUnavailableBeforeSubmit,
            .focusReadinessFailed,
            .functionKeyPostFailed,
            .stoppingFocusLost,
            .markedTextCommitTimedOut
        ]

        for reason in reasons {
            let identity = coordinator.beginRecording()
            coordinator.abandonRecording(identity: identity, reason: reason)
            coordinator.abandonRecording(identity: identity, reason: .sessionCancelled)
            XCTAssertEqual(coordinator.state(for: identity.requestId), .cancelled)
        }

        logger.flush()
        let rows = logger.storedEventSummaries()
        XCTAssertEqual(rows.map(\.event), reasons.flatMap { _ in ["recording_started", "task_cancelled"] })
        let loggedReasons = try rows
            .filter { $0.event == "task_cancelled" }
            .map { row -> String in
                let details = try XCTUnwrap(row.detailsJSON)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(details.utf8)) as? [String: String])
                return try XCTUnwrap(object["reason"])
            }
        XCTAssertEqual(loggedReasons, reasons.map(\.rawValue))
    }
    func testControllerMilestonesAreAppendedWithIndependentTimestamps() async throws {
        let sender = ControllableOrderSender()
        let logger = PasteOrderEventLogger(side: "controller-test", databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("paste-orders-\(UUID().uuidString).sqlite3"))
        let coordinator = DirectPasteOrderCoordinator(
            logger: logger,
            sendOperation: { text, identity, event in try await sender.send(text: text, identity: identity, transportEvent: event) }
        )
        let identity = submit("milestones", to: coordinator)
        try await sender.waitForRequestCount(1)
        await sender.succeed(identity)
        try await waitUntil { coordinator.state(for: identity.requestId) == .acknowledgedEventPosted }
        logger.flush()
        XCTAssertEqual(
            logger.storedEventSummaries().map(\.event),
            ["recording_started", "transcription_ready", "request_created", "http_send_started", "response_received", "ack_validated"]
        )
    }

    func testControllerLifecycleMilestonesAppendWithoutTextOrHash() {
        let logger = PasteOrderEventLogger(
            side: "controller-test",
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-orders-\(UUID().uuidString).sqlite3")
        )
        let coordinator = DirectPasteOrderCoordinator(
            logger: logger,
            sendOperation: { _, _, _ in throw TestWaitError.timeout }
        )
        let identity = coordinator.beginRecording()
        let events: [DirectPasteLifecycleEvent] = [
            .focusReady,
            .inputSourceReady,
            .functionKeyDownPosted,
            .markedTextStarted,
            .functionKeyUpPosted,
            .markedTextCommitted,
            .finalTextLocked
        ]
        for event in events {
            coordinator.recordLifecycleEvent(identity: identity, event: event)
        }
        logger.flush()

        let rows = logger.storedEventSummaries()
        XCTAssertEqual(rows.map(\.event), ["recording_started"] + events.map(\.rawValue))
        XCTAssertTrue(rows.allSatisfy { $0.textSHA256 == nil })
    }
    private func submit(_ text: String, to coordinator: DirectPasteOrderCoordinator) -> PasteOrderIdentity {
        let identity = coordinator.beginRecording()
        coordinator.transcriptionReady(identity: identity, textLength: text.count)
        coordinator.submit(identity: identity, text: text, targetProcessIdentifier: 1, targetBundleIdentifier: "target")
        return identity
    }
    private func makeCoordinator(sender: ControllableOrderSender, countChanged: @escaping (Int) -> Void = { _ in }) -> DirectPasteOrderCoordinator {
        DirectPasteOrderCoordinator(
            logger: PasteOrderEventLogger(side: "controller-test", databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("paste-orders-\(UUID().uuidString).sqlite3")),
            sendOperation: { text, identity, event in try await sender.send(text: text, identity: identity, transportEvent: event) },
            onUnconfirmedCountChanged: countChanged
        )
    }
    private func waitUntil(timeoutNanoseconds: UInt64 = 2_000_000_000, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw TestWaitError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

final class RemoteClipboardClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }
    func testV2RequestAndAcknowledgementValidateAllIdentityFields() async throws {
        let identity = PasteOrderIdentity(requestId: UUID(), controllerSessionId: UUID(), sequence: 42)
        StubURLProtocol.requestHandler = { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.capturedBody()) as? [String: Any])
            XCTAssertEqual(json["requestId"] as? String, identity.requestId.uuidString)
            XCTAssertEqual(json["controllerSessionId"] as? String, identity.controllerSessionId.uuidString)
            XCTAssertEqual((json["sequence"] as? NSNumber)?.int64Value, identity.sequence)
            XCTAssertEqual(json["text"] as? String, "remote paste test")
            return try Self.response(for: request, json: Self.validResponseJSON(identity: identity))
        }
        var events: [RemoteClipboardTransportEvent] = []
        let ack = try await makeClient().paste(text: "remote paste test", identity: identity, onTransportEvent: { events.append($0) })
        XCTAssertEqual(ack.requestId, identity.requestId)
        XCTAssertEqual(ack.controllerSessionId, identity.controllerSessionId)
        XCTAssertEqual(ack.sequence, identity.sequence)
        XCTAssertEqual(events.count, 1)
    }
    func testIdentityHashProtocolAndEventMismatchesFailOnlyThisCall() async throws {
        let identity = PasteOrderIdentity(requestId: UUID(), controllerSessionId: UUID(), sequence: 7)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["requestId"] = UUID().uuidString }, { $0["controllerSessionId"] = UUID().uuidString },
            { $0["sequence"] = 999 }, { $0["sha256"] = "bad" },
            { $0["protocolVersion"] = 1 }, { $0["eventPosted"] = false }
        ]
        for mutate in mutations {
            StubURLProtocol.requestHandler = { request in
                var json = Self.validResponseJSON(identity: identity)
                mutate(&json)
                return try Self.response(for: request, json: json)
            }
            do {
                _ = try await makeClient().paste(text: "remote paste test", identity: identity)
                XCTFail("Mismatched acknowledgement must fail")
            } catch { XCTAssertTrue(error is RemoteClipboardClientError) }
        }
    }
    private func makeClient() -> RemoteClipboardClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return RemoteClipboardClient(baseURL: URL(string: "http://127.0.0.1:17771")!, session: URLSession(configuration: configuration))
    }
    private static func validResponseJSON(identity: PasteOrderIdentity) -> [String: Any] {
        ["ok": true, "protocolVersion": RemoteClipboardClient.protocolVersion,
         "sha256": "e5e423eff5368461ebd6009241487740ba223d6bc12e13f777cb191f2484a8c5", "changeCount": 42,
         "requestId": identity.requestId.uuidString, "controllerSessionId": identity.controllerSessionId.uuidString,
         "sequence": identity.sequence, "eventPosted": true, "targetProcessIdentifier": 123,
         "targetBundleIdentifier": "com.example.target"]
    }
    private static func response(for request: URLRequest, json: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, try JSONSerialization.data(withJSONObject: json))
    }
}

final class PasteOrderEventLoggerTests: XCTestCase {
    func testSchemaStoresBothTimestampsAndDoesNotPersistDefaultHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString).sqlite3")
        let logger = PasteOrderEventLogger(side: "test", databaseURL: url)
        let identity = PasteOrderIdentity(requestId: UUID(), controllerSessionId: UUID(), sequence: 1)
        logger.capture(identity: identity, event: "request_created", protocolVersion: 2, textLength: 11)
        logger.flush()
        let columns = logger.schemaColumnNames()
        XCTAssertTrue(columns.isSuperset(of: ["request_id", "controller_session_id", "sequence", "process_instance_id", "side", "event", "event_at_utc_ms", "event_at_monotonic_ns", "protocol_version", "text_length", "text_sha256", "target_pid", "target_bundle_id", "pasteboard_change_count", "http_status", "error_code", "duration_ms", "details_json"]))
        let row = try XCTUnwrap(logger.storedEventSummaries().first)
        XCTAssertGreaterThan(row.eventAtUTCMilliseconds, 0)
        XCTAssertGreaterThan(row.eventAtMonotonicNanoseconds, 0)
        XCTAssertNil(row.textSHA256)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            let sidecarAttributes = try FileManager.default.attributesOfItem(atPath: url.path + suffix)
            let sidecarPermissions = (sidecarAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(sidecarPermissions & 0o777, 0o600)
        }
    }
}

private actor ControllableOrderSender {
    typealias Continuation = CheckedContinuation<RemotePasteAcknowledgement, Error>
    private var continuations: [UUID: Continuation] = [:]
    private var transportEvents: [UUID: (RemoteClipboardTransportEvent) -> Void] = [:]
    private var counts: [UUID: Int] = [:]
    func send(text: String, identity: PasteOrderIdentity, transportEvent: @escaping (RemoteClipboardTransportEvent) -> Void) async throws -> RemotePasteAcknowledgement {
        counts[identity.requestId, default: 0] += 1
        transportEvents[identity.requestId] = transportEvent
        return try await withCheckedThrowingContinuation { continuations[identity.requestId] = $0 }
    }
    func succeed(_ identity: PasteOrderIdentity) {
        transportEvents.removeValue(forKey: identity.requestId)?(.responseReceived(httpStatus: 200, durationMilliseconds: 1))
        continuations.removeValue(forKey: identity.requestId)?.resume(returning: RemotePasteAcknowledgement(ok: true, protocolVersion: 2, sha256: "unused", changeCount: 1, requestId: identity.requestId, controllerSessionId: identity.controllerSessionId, sequence: identity.sequence, eventPosted: true, targetProcessIdentifier: 123, targetBundleIdentifier: "target"))
    }
    func fail(_ identity: PasteOrderIdentity, error: Error) {
        transportEvents[identity.requestId] = nil
        continuations.removeValue(forKey: identity.requestId)?.resume(throwing: error)
    }
    func sendCount(for requestId: UUID) -> Int { counts[requestId, default: 0] }
    func waitForRequestCount(_ expected: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while counts.values.reduce(0, +) < expected {
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw TestWaitError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
private enum TestWaitError: Error { case timeout }
private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.requestHandler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    func capturedBody() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
