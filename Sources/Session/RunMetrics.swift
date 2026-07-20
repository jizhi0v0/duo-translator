import Foundation

/// Per-run performance readout for an LLM engine: how fast the first token
/// arrived and how fast the rest streamed. Purely derived from timestamps and
/// the provider's token usage (when reported), so it is a plain value type and
/// its math is unit-testable without a live run.
struct RunMetrics: Equatable, Sendable {
    /// Request start → first token. `nil` if the run produced no token.
    let ttft: TimeInterval?
    /// Request start → done (end-to-end wall time).
    let total: TimeInterval
    /// First token → done: the decode window throughput is measured over, so
    /// TTFT (queue + prefill) doesn't drag the output-speed number down.
    let generation: TimeInterval
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let outputChars: Int
    /// Output tokens per second over the decode window; `nil` when the provider
    /// didn't report a completion-token count (then `charsPerSecond` is used).
    let tokensPerSecond: Double?
    /// Chars-per-second fallback over the decode window.
    let charsPerSecond: Double?

    /// Build from raw timings/counts. Kept side-effect free (takes intervals,
    /// not `Date`s) so tests can pin exact numbers.
    static func make(
        total: TimeInterval,
        ttft: TimeInterval?,
        outputChars: Int,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?
    ) -> RunMetrics {
        // Decode window = total − TTFT, floored at 0. Fall back to the full run
        // when no first-token time was captured.
        let generation = max(0, ttft.map { total - $0 } ?? total)
        let perSecond: (Int) -> Double? = { count in
            generation > 0 ? Double(count) / generation : nil
        }
        return RunMetrics(
            ttft: ttft,
            total: total,
            generation: generation,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            outputChars: outputChars,
            tokensPerSecond: completionTokens.flatMap(perSecond),
            charsPerSecond: perSecond(outputChars)
        )
    }

    /// Multi-line summary for the header tooltip. Order: responsiveness (TTFT),
    /// speed, total time, then token usage — falling back to a char count when
    /// the provider is silent on tokens.
    var tooltip: String {
        var lines: [String] = []
        if let ttft {
            lines.append("首 Token \(Self.seconds(ttft, decimals: 2))")
        }
        if let tps = tokensPerSecond {
            lines.append("输出速度 \(Int(tps.rounded())) tok/s")
        } else if let cps = charsPerSecond {
            lines.append("输出速度 \(Int(cps.rounded())) 字/s")
        }
        lines.append("总耗时 \(Self.seconds(total, decimals: 1))")
        if let completion = completionTokens {
            if let prompt = promptTokens {
                let total = totalTokens.map { "（共 \($0)）" } ?? ""
                lines.append("Token \(prompt)→\(completion)\(total)")
            } else {
                lines.append("输出 Token \(completion)")
            }
        } else {
            lines.append("输出 \(outputChars) 字")
        }
        return lines.joined(separator: "\n")
    }

    private static func seconds(_ value: TimeInterval, decimals: Int) -> String {
        String(format: "%.\(decimals)fs", value)
    }

    // MARK: - Display (split value/unit for the popover's stat tiles)

    /// First-token latency as a big number + unit, or nil if no token arrived.
    var ttftDisplay: (value: String, unit: String)? {
        guard let ttft else { return nil }
        return (String(format: "%.2f", ttft), "s")
    }

    /// Headline throughput: tokens/s when the provider reported usage, else a
    /// clearly-labelled chars/s fallback. Nil when the decode window was zero.
    var speedDisplay: (value: String, unit: String)? {
        if let tps = tokensPerSecond { return (String(Int(tps.rounded())), "tok/s") }
        if let cps = charsPerSecond { return (String(Int(cps.rounded())), "字/s") }
        return nil
    }

    var totalDisplay: (value: String, unit: String) {
        (String(format: "%.1f", total), "s")
    }

    /// `prompt → completion` when both are known, just completion otherwise;
    /// nil when the provider reported no token usage at all.
    var tokenFlow: String? {
        guard let completion = completionTokens else { return nil }
        guard let prompt = promptTokens else { return "\(completion)" }
        return "\(prompt) → \(completion)"
    }
}
