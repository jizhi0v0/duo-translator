import Foundation

/// One long-lived URLSession shared by every engine so connections to the same
/// host stay warm (HTTP keep-alive / HTTP-2 reuse) across translations. The
/// first request to a host pays the TCP+TLS handshake; subsequent ones reuse
/// the pooled connection. An occasional cold start after idle is acceptable.
enum HTTPClient {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
