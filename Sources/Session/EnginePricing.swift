import Foundation

/// What one engine charges, in the unit every provider quotes: currency per
/// million tokens. Zero means "unknown" — the readout then shows no cost rather
/// than a confident 0.00.
///
/// Prices live on the engine profile because they are per-model and change
/// often; a table baked into the app would be wrong within weeks and wrong
/// silently, which is worse than absent.
struct EnginePricing: Sendable, Equatable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    /// Cached input, when the provider discounts it (OpenAI bills cache reads
    /// at half, Anthropic at a tenth). Falls back to the full input price.
    let cachedInputPerMillion: Double?

    init?(profile: EngineProfile) {
        guard profile.inputPricePerMTok > 0 || profile.outputPricePerMTok > 0 else { return nil }
        inputPerMillion = profile.inputPricePerMTok
        outputPerMillion = profile.outputPricePerMTok
        cachedInputPerMillion =
            profile.cachedInputPricePerMTok > 0 ? profile.cachedInputPricePerMTok : nil
    }

    init(inputPerMillion: Double, outputPerMillion: Double, cachedInputPerMillion: Double? = nil) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
    }

    /// Cost of one run. Cached prompt tokens are billed at the cache rate and
    /// removed from the full-price prompt count — providers report them as a
    /// *subset* of `prompt`, so charging both would double-count them.
    func cost(of usage: TokenUsage) -> Double? {
        guard let prompt = usage.prompt ?? usage.total else { return nil }
        let cached = min(usage.cachedPrompt ?? 0, prompt)
        let fullPrice = Double(prompt - cached) / 1_000_000 * inputPerMillion
        let cachedPrice =
            Double(cached) / 1_000_000 * (cachedInputPerMillion ?? inputPerMillion)
        // Anthropic reports cache writes on top of `input_tokens`, at a premium
        // we don't model per-provider; charge them as plain input.
        let writePrice = Double(usage.cacheWrite ?? 0) / 1_000_000 * inputPerMillion
        let output = Double(usage.completion ?? 0) / 1_000_000 * outputPerMillion
        return fullPrice + cachedPrice + writePrice + output
    }
}
