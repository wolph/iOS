import OHHTTPStubs
import OHHTTPStubsSwift
import PromiseKit
@testable import Shared
import XCTest

final class HomeAssistantAPIMobileAppConfigTests: XCTestCase {
    /// Stub responses are delivered off the main queue, so the count they feed is guarded.
    private final class RequestRecorder {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.withLock { value }
        }

        func record() {
            lock.withLock { value += 1 }
        }
    }

    private var api: HomeAssistantAPI!
    private var recorder: RequestRecorder!
    /// The present rather than a fixed instant, so nothing time-based elsewhere in the API reads
    /// the fake server as decades stale.
    private var now = Date()

    override func setUp() {
        super.setUp()
        let previousDate = Current.date
        addTeardownBlock { Current.date = previousDate }
        setNow(now)

        let previousInterval = HomeAssistantAPI.mobileAppConfigRetryInterval
        addTeardownBlock { HomeAssistantAPI.mobileAppConfigRetryInterval = previousInterval }
        // Shorter than the fake token's hour, so advancing past it doesn't refresh the token.
        HomeAssistantAPI.mobileAppConfigRetryInterval = 60

        recorder = RequestRecorder()
        api = HomeAssistantAPI(server: .fake())
    }

    override func tearDown() {
        HTTPStubs.removeAllStubs()
        api = nil
        super.tearDown()
    }

    private func setNow(_ date: Date) {
        Current.date = { date }
    }

    private func stubMobileAppConfig(status: Int32) {
        _ = stub(condition: { $0.url?.path.hasSuffix("/ios/config") == true }) { [recorder] _ in
            recorder?.record()
            return HTTPStubsResponse(data: Data(), statusCode: status, headers: nil)
        }
    }

    /// The request runs on every connect, and a server without the `ios` component answers 404
    /// every time. The integration can be set up without an upgrade, so the server is asked again
    /// after a while rather than never.
    func testAMissingComponentIsAskedAboutAgainAfterTheRetryInterval() throws {
        stubMobileAppConfig(status: 404)

        let config = try hang(api.GetMobileAppConfig())
        _ = try hang(api.GetMobileAppConfig())

        XCTAssertTrue(config.push.categories.isEmpty)
        XCTAssertEqual(recorder.count, 1)

        setNow(now.addingTimeInterval(HomeAssistantAPI.mobileAppConfigRetryInterval))
        _ = try hang(api.GetMobileAppConfig())

        XCTAssertEqual(recorder.count, 2)
    }

    /// A server that failed for any other reason may answer next time, so only a 404 is remembered.
    /// 400 rather than a 5xx, which Alamofire's retry policy would try again on its own.
    func testOtherFailuresAreAskedAboutAgainAtOnce() {
        stubMobileAppConfig(status: 400)

        XCTAssertThrowsError(try hang(api.GetMobileAppConfig()))
        XCTAssertThrowsError(try hang(api.GetMobileAppConfig()))

        XCTAssertEqual(recorder.count, 2)
    }
}
