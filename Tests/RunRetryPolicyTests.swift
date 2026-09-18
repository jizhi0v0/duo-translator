import XCTest
@testable import DuoTranslator

/// The retry is silent, so its boundaries are the whole design: it must never
/// restart something the reader has already started reading, and never turn a
/// deterministic failure into two of them.
final class RunRetryPolicyTests: XCTestCase {
    private let lost = URLError(.networkConnectionLost)

    func testRetriesAConnectionLostBeforeTheFirstToken() {
        XCTAssertTrue(
            RunRetryPolicy.shouldRetry(after: lost, receivedFirstToken: false, attempt: 0)
        )
    }

    func testDoesNotRetryOnceATokenHasBeenShown() {
        // Restarting here would wipe a half-read translation and pay twice.
        XCTAssertFalse(
            RunRetryPolicy.shouldRetry(after: lost, receivedFirstToken: true, attempt: 0)
        )
    }

    func testRetriesOnlyOnce() {
        XCTAssertFalse(
            RunRetryPolicy.shouldRetry(after: lost, receivedFirstToken: false, attempt: 1)
        )
    }

    func testRetriesAProxyThatBlinked() {
        XCTAssertTrue(RunRetryPolicy.shouldRetry(
            after: URLError(.cannotConnectToHost), receivedFirstToken: false, attempt: 0
        ))
    }

    func testDoesNotRetryATimeout() {
        // Before the first token a timeout is usually a slow model, and a retry
        // only doubles the wait.
        XCTAssertFalse(RunRetryPolicy.shouldRetry(
            after: URLError(.timedOut), receivedFirstToken: false, attempt: 0
        ))
    }

    func testDoesNotRetryADeterministicFailure() {
        for error: Error in [
            EngineError.http(status: 500, body: "boom"),
            EngineError.http(status: 401, body: "bad key"),
            EngineError.missingAPIKey,
            EngineError.decoding("unexpected shape"),
        ] {
            XCTAssertFalse(
                RunRetryPolicy.shouldRetry(after: error, receivedFirstToken: false, attempt: 0),
                "\(error) must not be retried"
            )
        }
    }

    func testDoesNotRetryCancellation() {
        XCTAssertFalse(RunRetryPolicy.shouldRetry(
            after: CancellationError(), receivedFirstToken: false, attempt: 0
        ))
    }
}
