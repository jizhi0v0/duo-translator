import Foundation

@MainActor
enum EngineFactory {
    /// Build engine instances for every enabled profile. Profiles whose engine
    /// isn't implemented yet (later milestones) are skipped.
    static func makeEngines(settings: SettingsStore, keychain: KeychainStore) -> [any TranslationEngine] {
        settings.enabledProfiles.compactMap { profile in
            switch profile.kind {
            case .openAICompat:
                return OpenAICompatEngine(profile: profile, apiKey: keychain.secret(for: profile.id) ?? "")
            case .anthropic, .deepL, .apple:
                return nil // M4
            }
        }
    }
}
