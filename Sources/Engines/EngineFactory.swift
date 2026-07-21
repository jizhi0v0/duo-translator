import Foundation

@MainActor
enum EngineFactory {
    /// Build engine instances for every enabled card that still resolves to a
    /// provider. The returned engines line up 1:1 with
    /// `settings.resolvedEnabledEngines`, in the same order.
    static func makeEngines(settings: SettingsStore, keychain: KeychainStore) -> [any TranslationEngine] {
        settings.resolvedEnabledEngines.map { makeEngine(profile: $0, keychain: keychain) }
    }

    /// Build a single engine from a resolved profile (used by per-card retry).
    /// The API key is fetched by provider id, so cards sharing a provider share
    /// its key.
    static func makeEngine(profile: EngineProfile, keychain: KeychainStore) -> any TranslationEngine {
        let apiKey = keychain.secret(for: profile.providerID) ?? ""
        switch profile.kind {
        case .openAICompat:
            return OpenAICompatEngine(profile: profile, apiKey: apiKey)
        case .anthropic:
            return AnthropicEngine(profile: profile, apiKey: apiKey)
        case .deepL:
            return DeepLEngine(profile: profile, apiKey: apiKey)
        case .apple:
            return AppleTranslationEngine(profile: profile)
        }
    }
}
