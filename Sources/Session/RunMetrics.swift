import Foundation

/// Per-run performance readout for an LLM engine: how fast the first token
/// arrived, how fast the rest streamed, what it cost, and where the waiting
/// went. Purely derived from timestamps and what the provider reported, so it
/// is a plain value type and its math is unit-testable without a live run.
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
    /// Prompt tokens the provider served from its cache (a subset of
    /// `promptTokens`), and reasoning tokens billed inside `completionTokens`.
    let cachedPromptTokens: Int?
    let reasoningTokens: Int?
    let outputChars: Int
    /// Output tokens per second over the decode window; `nil` when the provider
    /// didn't report a completion-token count (then `charsPerSecond` is used).
    let tokensPerSecond: Double?
    /// Chars-per-second fallback over the decode window.
    let charsPerSecond: Double?
    /// Cost of this run in the provider's currency, when prices are configured.
    let cost: Double?
    /// Longest gap between two streamed chunks: how badly the provider stalled
    /// mid-stream. Invisible on screen now that the panel paces its reveal.
    let longestChunkGap: TimeInterval?
    /// Connection setup versus server wait, when URLSession reported them.
    let network: NetworkTiming?
    /// Model id the provider echoed back — not always the one requested.
    let reportedModel: String?

    /// Build from raw timings/counts. Kept side-effect free (takes intervals,
    /// not `Date`s) so tests can pin exact numbers.
    static func make(
        total: TimeInterval,
        ttft: TimeInterval?,
        outputChars: Int,
        usage: TokenUsage? = nil,
        chunkGaps: [TimeInterval] = [],
        network: NetworkTiming? = nil,
        reportedModel: String? = nil,
        pricing: EnginePricing? = nil
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
            promptTokens: usage?.prompt,
            completionTokens: usage?.completion,
            totalTokens: usage?.total,
            cachedPromptTokens: usage?.cachedPrompt,
            reasoningTokens: usage?.reasoning,
            outputChars: outputChars,
            tokensPerSecond: usage?.completion.flatMap(perSecond),
            charsPerSecond: perSecond(outputChars),
            cost: usage.flatMap { u in pricing?.cost(of: u) },
            longestChunkGap: chunkGaps.max(),
            network: network,
            reportedModel: reportedModel
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
        if let costDisplay { lines.append("成本 \(costDisplay)") }
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

    /// Sub-cent runs are the norm here, so show enough digits to be meaningful
    /// rather than rounding every translation to 0.00.
    var costDisplay: String? {
        guard let cost else { return nil }
        if cost > 0 && cost < 0.01 { return String(format: "%.4f", cost) }
        return String(format: "%.2f", cost)
    }

    /// Only worth a line when the provider actually served part of the prompt
    /// from cache — with a short shared prefix this stays nil.
    var cacheDisplay: String? {
        guard let cached = cachedPromptTokens, cached > 0 else { return nil }
        guard let prompt = promptTokens, prompt > 0 else { return "\(cached)" }
        let share = Int((Double(cached) / Double(prompt) * 100).rounded())
        return "\(cached)（\(share)%）"
    }

    /// Reasoning tokens are billed inside the completion count, so they are
    /// shown as a share of it: a short translation that cost 3000 tokens is
    /// explained entirely by this line.
    var reasoningDisplay: String? {
        guard let reasoning = reasoningTokens, reasoning > 0 else { return nil }
        guard let completion = completionTokens, completion > 0 else { return "\(reasoning)" }
        let share = Int((Double(reasoning) / Double(completion) * 100).rounded())
        return "\(reasoning)（占输出 \(share)%）"
    }

    /// Time to first byte, the headline number the "首字节" row shows. The
    /// handshake / server split is appended when URLSession's metrics arrived
    /// in time. Doesn't repeat "首字节" itself — that's the row's label.
    var networkDisplay: String? {
        guard let network else { return nil }
        var detail: [String] = []
        if let connect = network.connect {
            detail.append("握手 \(Self.milliseconds(connect))")
        } else if network.reusedConnection == true {
            detail.append("复用连接")
        }
        if let serverWait = network.serverWait {
            detail.append("服务端 \(Self.milliseconds(serverWait))")
        }
        let headline = Self.milliseconds(network.toFirstByte)
        return detail.isEmpty ? headline : headline + "（" + detail.joined(separator: " · ") + "）"
    }

    /// Longest gap between two streamed chunks, as a plain duration — the
    /// "最长停顿" row supplies the label. Under ~0.5s the gaps are ordinary
    /// token jitter and the row doesn't appear at all.
    var stallDisplay: String? {
        guard let gap = longestChunkGap, gap >= 0.5 else { return nil }
        return Self.seconds(gap, decimals: 1)
    }

    /// The model the provider says it ran — surfaced only when it differs from
    /// what was asked for, which is the case worth noticing (a gateway quietly
    /// routing elsewhere).
    func routedModelDisplay(requested: String) -> String? {
        guard let reportedModel, !reportedModel.isEmpty else { return nil }
        let asked = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, reportedModel != asked else { return nil }
        return reportedModel
    }

    private static func milliseconds(_ value: TimeInterval) -> String {
        "\(Int((value * 1000).rounded()))ms"
    }
}
