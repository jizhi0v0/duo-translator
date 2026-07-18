import Foundation

@MainActor
enum EngineFactory {
    /// Build engine instances for every enabled profile. Profiles whose engine
    /// isn't implemented yet (later milestones) are skipped.
    static func makeEngines(settings: SettingsStore, keychain: KeychainStore) -> [any TranslationEngine] {
        settings.enabledProfiles.map { makeEngine(profile: $0, keychain: keychain) }
    }

    /// Build a single engine (used by per-card retry).
    static func makeEngine(profile: EngineProfile, keychain: KeychainStore) -> any TranslationEngine {
        switch profile.kind {
        case .openAICompat:
            return OpenAICompatEngine(profile: profile, apiKey: keychain.secret(for: profile.id) ?? "")
        case .anthropic:
            return AnthropicEngine(profile: profile, apiKey: keychain.secret(for: profile.id) ?? "")
        case .deepL:
            return DeepLEngine(profile: profile, apiKey: keychain.secret(for: profile.id) ?? "")
        case .apple:
            return AppleTranslationEngine(profile: profile)
        }
    }
}
