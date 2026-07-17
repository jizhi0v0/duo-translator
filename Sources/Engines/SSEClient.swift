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
    static func events(
        for request: URLRequest,
        session: URLSession = HTTPClient.shared
    ) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
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
