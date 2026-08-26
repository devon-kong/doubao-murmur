import Foundation
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

    func testOnlyCompatibilityRoutePrepublishesControllerClipboard() {
        XCTAssertFalse(PasteRouter.shouldPrepublishLocalClipboard(for: .local))
        XCTAssertTrue(PasteRouter.shouldPrepublishLocalClipboard(for: .uuCompatibility))
        XCTAssertFalse(PasteRouter.shouldPrepublishLocalClipboard(for: .uuDirect))
        XCTAssertFalse(DirectPasteFailureHandler.plan(for: .remoteWriteFailed).shouldPaste)
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
        XCTAssertEqual(RemoteClipboardFailurePrompt.writeFailure.title, "被控制端粘贴失败")
        XCTAssertEqual(RemoteClipboardFailurePrompt.writeFailure.message, "请检查被控制端助手、辅助功能权限和 UU 端口映射，或切换到兼容模式。")
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

}

final class RemoteClipboardClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRemotePasteRequiresMatchingRequestHashAndEventAcknowledgement() async throws {
        let requestId = UUID()
        let text = "remote paste test"
        StubURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/paste")
            XCTAssertEqual(request.httpMethod, "POST")
            let requestBody = try request.capturedBody()
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: String]
            )
            XCTAssertEqual(requestJSON["requestId"], requestId.uuidString)
            XCTAssertEqual(requestJSON["text"], text)

            let responseJSON: [String: Any] = [
                "ok": true,
                "protocolVersion": RemoteClipboardClient.protocolVersion,
                "sha256": "e5e423eff5368461ebd6009241487740ba223d6bc12e13f777cb191f2484a8c5",
                "changeCount": 42,
                "requestId": requestId.uuidString,
                "eventPosted": true,
                "targetProcessIdentifier": 123,
                "targetBundleIdentifier": "com.example.target"
            ]
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = RemoteClipboardClient(
            baseURL: URL(string: "http://127.0.0.1:17771")!,
            session: URLSession(configuration: configuration)
        )

        let acknowledgement = try await client.paste(text: text, requestId: requestId)
        XCTAssertTrue(acknowledgement.eventPosted)
        XCTAssertEqual(acknowledgement.requestId, requestId)
        XCTAssertEqual(acknowledgement.targetProcessIdentifier, 123)
        XCTAssertEqual(acknowledgement.targetBundleIdentifier, "com.example.target")
    }

    func testRemotePasteRejectsAcknowledgementWithoutPostedEvent() async throws {
        let requestId = UUID()
        StubURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "ok": true,
                "protocolVersion": RemoteClipboardClient.protocolVersion,
                "sha256": "e5e423eff5368461ebd6009241487740ba223d6bc12e13f777cb191f2484a8c5",
                "changeCount": 42,
                "requestId": requestId.uuidString,
                "eventPosted": false,
                "targetProcessIdentifier": 123
            ]
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = RemoteClipboardClient(
            baseURL: URL(string: "http://127.0.0.1:17771")!,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.paste(text: "remote paste test", requestId: requestId)
            XCTFail("A paste response without eventPosted must not be accepted")
        } catch let error as RemoteClipboardClientError {
            guard case .rejected = error else {
                return XCTFail("Expected rejected acknowledgement, got \(error)")
            }
        }
    }

    func testRemotePasteRejectsMismatchedRequestId() async throws {
        let requestId = UUID()
        StubURLProtocol.requestHandler = { request in
            let responseJSON: [String: Any] = [
                "ok": true,
                "protocolVersion": RemoteClipboardClient.protocolVersion,
                "sha256": "e5e423eff5368461ebd6009241487740ba223d6bc12e13f777cb191f2484a8c5",
                "changeCount": 42,
                "requestId": UUID().uuidString,
                "eventPosted": true,
                "targetProcessIdentifier": 123
            ]
            let data = try JSONSerialization.data(withJSONObject: responseJSON)
            let response = try XCTUnwrap(
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = RemoteClipboardClient(
            baseURL: URL(string: "http://127.0.0.1:17771")!,
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.paste(text: "remote paste test", requestId: requestId)
            XCTFail("A paste response with a different requestId must not be accepted")
        } catch let error as RemoteClipboardClientError {
            guard case .requestMismatch = error else {
                return XCTFail("Expected request mismatch, got \(error)")
            }
        }
    }
}

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
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func capturedBody() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
