import Foundation

/// Whether a failed engine run is worth one silent retry.
///
/// Deliberately narrow on two axes.
///
/// *Nothing may have been shown yet.* A retry is invisible only before the
/// first token: once any chunk (content or reasoning) has reached the card,
/// restarting would wipe a half-read translation off the screen and pay for
/// the tokens a second time. A mid-stream failure therefore keeps exactly what
/// it has today — the error and the card's 重试此引擎 button.
///
/// *Only errors a second attempt actually fixes.* `networkConnectionLost` is
/// the keep-alive race: URLSession hands the request to a pooled connection the
/// peer has already closed, and a fresh connection is precisely the cure —
/// this is the one that was reported from the field. `cannotConnectToHost`
/// covers a local proxy that blinked. Everything else is either deterministic
/// (HTTP status, a bad key, a decoding failure — retrying fails twice as
/// slowly) or ambiguous in a way that costs the reader time: a timeout before
/// the first token is usually a slow model, and retrying just doubles the wait.
enum RunRetryPolicy {
    /// Pause before the retry, so a peer that closed the connection has a
    /// moment and we never hammer it.
    static let backoff: Duration = .milliseconds(200)

    static func shouldRetry(after error: Error, receivedFirstToken: Bool, attempt: Int) -> Bool {
        guard attempt == 0, !receivedFirstToken else { return false }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }
}
