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
}
