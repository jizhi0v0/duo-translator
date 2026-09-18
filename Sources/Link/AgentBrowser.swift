import Foundation

/// Runs the bundled `agent-browser` CLI (Apache-2.0, in `Contents/Helpers`) to
/// fetch a page's readable content. `read <url> --json` drives a headless
/// Chromium browser (pointed at via `--executable-path`) and returns the page as
/// agent-readable text — the extraction is maintained upstream, so we don't
/// babysit per-site DOM logic. The daemon it spawns self-terminates via
/// `AGENT_BROWSER_IDLE_TIMEOUT_MS`.
enum AgentBrowser {
    struct Article {
        let title: String
        let text: String
    }

    enum AgentBrowserError: LocalizedError {
        /// The bundled CLI is missing (should not happen in a shipped build).
        case unavailable
        /// No Chromium browser is installed / selected to drive the fetch.
        case noBrowser
        case launch(String)
        case fetchFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable: return "内置的 agent-browser 组件缺失,请重装 DuoTranslator。"
            case .noBrowser: return "没有可用的浏览器。链接翻译需要一个 Chromium 内核浏览器(Chrome / Edge / Brave / Arc 等),请在设置里选择。"
            case .launch(let m): return "启动抓取失败:\(m)"
            case .fetchFailed(let m): return "抓取失败:\(m)"
            case .empty: return "没能从这个页面提取到正文。"
            }
        }
    }

    /// The bundled CLI in `DuoTranslator.app/Contents/Helpers/agent-browser`.
    static var bundledBinary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agent-browser")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Fetch `url` via `agent-browser read`, driving the browser at `browserPath`.
    /// Returns the readable content as paragraph text plus a title parsed from the
    /// first markdown heading.
    static func read(
        url: URL,
        browserPath: String,
        binary: URL,
        timeoutMS: Int = 25000
    ) async throws -> Article {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            "read", url.absoluteString,
            "--json",
            "--executable-path", browserPath,
            "--timeout", String(timeoutMS),
        ]
        var env = ProcessInfo.processInfo.environment
        // Let the background daemon shut itself down shortly after we're done, so
        // repeated link translations don't leave a headless browser resident.
        env["AGENT_BROWSER_IDLE_TIMEOUT_MS"] = "3000"
        // A GUI app has no shell proxy vars; without them agent-browser's direct
        // fetch times out behind a system proxy (Surge/ClashX). Inject them.
        for (k, v) in SystemProxy.environmentOverrides() { env[k] = v }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw AgentBrowserError.launch(error.localizedDescription)
        }

        // Swift-side backstop: if the CLI hangs past its own timeout, terminate it
        // (which closes the pipes and unblocks the drains below).
        let killer = Task {
            try? await Task.sleep(for: .milliseconds(timeoutMS + 5000))
            if proc.isRunning { proc.terminate() }
        }
        // Drain both pipes concurrently so a large page can't deadlock on a full
        // pipe buffer while we wait for exit.
        async let outData = drain(outPipe.fileHandleForReading)
        async let errData = drain(errPipe.fileHandleForReading)
        let out = await outData
        let err = await errData
        proc.waitUntilExit()
        killer.cancel()

        guard let obj = try? JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            let stderr = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentBrowserError.fetchFailed(stderr?.isEmpty == false ? stderr! : "无输出")
        }
        if (obj["success"] as? Bool) == false {
            throw AgentBrowserError.fetchFailed((obj["error"] as? String) ?? "未知错误")
        }
        let content = ((obj["data"] as? [String: Any])?["content"] as? String) ?? ""
        let text = ArticleText.normalize(ArticleText.articleBody(content))
        guard !text.isEmpty else { throw AgentBrowserError.empty }
        let title = ArticleText.firstHeading(content) ?? (url.host ?? url.absoluteString)
        return Article(title: title, text: text)
    }

    /// Read a file handle to EOF off the main thread. EOF arrives when the child
    /// closes its end (on exit or termination).
    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                cont.resume(returning: data)
            }
        }
    }
}
