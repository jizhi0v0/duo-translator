import Foundation

/// Bridges the macOS system proxy (System Settings › Network › Proxies, which
/// tools like Surge/ClashX configure) into the env vars a child CLI's HTTP
/// client reads. agent-browser's `read` does an initial direct HTTP fetch with
/// a client that honors `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` — but a GUI app
/// (unlike a shell) has none of those, so behind a proxy the fetch times out
/// even though Chrome (which uses the *system* proxy) would succeed. We copy the
/// system proxy into the process env to close that gap.
enum SystemProxy {
    /// `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` (and lowercase aliases) derived
    /// from the current system proxy config. Empty when no manual proxy is set —
    /// in which case a direct connection is used, as before.
    static func environmentOverrides(
        settings: [String: Any]? = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
    ) -> [String: String] {
        guard let settings else { return [:] }

        // A manual HTTP-CONNECT proxy is reached over http even when it carries
        // https traffic, so both HTTP_PROXY and HTTPS_PROXY use the http scheme.
        func url(enable: String, host: String, port: String) -> String? {
            guard (settings[enable] as? Int) == 1,
                  let h = settings[host] as? String, !h.isEmpty else { return nil }
            let p = settings[port] as? Int ?? 0
            return p > 0 ? "http://\(h):\(p)" : "http://\(h)"
        }

        var env: [String: String] = [:]
        let http = url(enable: "HTTPEnable", host: "HTTPProxy", port: "HTTPPort")
        let https = url(enable: "HTTPSEnable", host: "HTTPSProxy", port: "HTTPSPort")
        if let http { env["HTTP_PROXY"] = http; env["http_proxy"] = http }
        if let https { env["HTTPS_PROXY"] = https; env["https_proxy"] = https }
        // Catch-all for the CLI's client; prefer the https proxy, else http.
        if let all = https ?? http { env["ALL_PROXY"] = all; env["all_proxy"] = all }
        return env
    }
}
