import Foundation

struct SSEEvent: Sendable {
    var event: String?
    var data: String
}

/// Minimal Server-Sent-Events client for OpenAI / Anthropic style streams.
///
/// Note: `AsyncLineSequence` drops empty lines, so we cannot rely on the
/// blank-line event delimiter. Both OpenAI and Anthropic emit single-line
/// `data:` frames (optionally preceded by an `event:` line), so each `data:`
/// line is emitted as one event carrying the most recent `event:` name.
enum SSEClient {
    /// - Parameter onTiming: called once with the connection timings, if
    ///   URLSession collected them before the body finished. They separate the
    ///   handshake from the server's own wait, which one TTFT number cannot.
    static func events(
        for request: URLRequest,
        session: URLSession = HTTPClient.shared,
        onTiming: (@Sendable (NetworkTiming) -> Void)? = nil
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let collector = TaskMetricsCollector()
                // Refinement from URLSession lands at task completion, which the
                // caller may never reach (breaking on `[DONE]` cancels the
                // task). Reporting it as it arrives means a run gets whatever
                // detail was available, never nothing.
                collector.onTiming = onTiming
                let requestStart = ContinuousClock.now
                do {
                    let (bytes, response) = try await session.bytes(
                        for: request, delegate: onTiming == nil ? nil : collector
                    )
                    collector.headersAt = requestStart.duration(to: .now)
                    if let onTiming, let elapsed = collector.headersAt {
                        onTiming(NetworkTiming(toFirstByte: elapsed.seconds))
                    }
                    guard let http = response as? HTTPURLResponse else {
                        throw EngineError.decoding("非 HTTP 响应")
                    }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line + "\n"
                            if body.count > 64_000 { break }
                        }
                        throw EngineError.http(status: http.statusCode, body: body)
                    }

                    var eventName: String?
                    for try await line in bytes.lines {
                        // Abort promptly when the run is cancelled (ESC / window
                        // close / re-translate) instead of draining the stream.
                        try Task.checkCancellation()
                        if line.hasPrefix("data:") {
                            let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            continuation.yield(SSEEvent(event: eventName, data: data))
                            eventName = nil
                        } else if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        }
                        // id:/retry:/comments ignored
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Collects `URLSessionTaskMetrics` for one streamed request.
///
/// The delegate callback lands when the task completes, which is the same
/// moment the byte stream ends — the two race, so the reader waits briefly
/// rather than assuming an order. Timings are a nice-to-have readout: if they
/// are late, the run simply reports without them.
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    /// Set once headers are in, so the refinement can carry the same
    /// self-measured number rather than replacing it with a narrower one.
    var headersAt: Duration? {
        get { lock.withLock { storedHeadersAt } }
        set { lock.withLock { storedHeadersAt = newValue } }
    }
    var onTiming: (@Sendable (NetworkTiming) -> Void)? {
        get { lock.withLock { storedOnTiming } }
        set { lock.withLock { storedOnTiming = newValue } }
    }
    private var storedHeadersAt: Duration?
    private var storedOnTiming: (@Sendable (NetworkTiming) -> Void)?

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last,
              let onTiming, let headersAt else { return }
        let connect: TimeInterval? = {
            // Present only for a fresh connection; a reused one skips the
            // handshake entirely, which is itself the useful signal.
            guard let start = transaction.domainLookupStartDate ?? transaction.connectStartDate,
                  let end = transaction.connectEndDate else { return nil }
            return end.timeIntervalSince(start)
        }()
        let serverWait: TimeInterval? = {
            guard let sent = transaction.requestEndDate,
                  let firstByte = transaction.responseStartDate else { return nil }
            return firstByte.timeIntervalSince(sent)
        }()
        onTiming(NetworkTiming(
            toFirstByte: headersAt.seconds,
            connect: connect,
            serverWait: serverWait,
            reusedConnection: transaction.isReusedConnection
        ))
    }
}

extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
