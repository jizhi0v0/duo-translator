import Vision

/// Resolves the persisted OCR selection into a live provider. Apple Vision is
/// the default and the fallback: any selection that no longer resolves to an
/// existing vision-capable engine (deleted profile, or a non-LLM kind) quietly
/// reverts to Apple, so OCR never breaks because a translation engine changed.
@MainActor
enum OCRFactory {
    /// Sentinel selection value for the built-in Vision path.
    static let appleSelection = "apple"

    static func makeProvider(settings: SettingsStore, keychain: KeychainStore) -> OCRProvider {
        let level: VNRequestTextRecognitionLevel = settings.ocrVisionLevel == "fast" ? .fast : .accurate
        let apple = AppleVisionOCRProvider(
            languages: settings.ocrLanguages,
            mergeParagraphs: settings.ocrMergesLines,
            level: level
        )

        guard settings.ocrProvider != appleSelection,
              let id = UUID(uuidString: settings.ocrProvider),
              let profile = settings.engineProfiles.first(where: { $0.id == id }),
              profile.kind.isLLM else {
            return apple
        }
        return LLMVisionOCRProvider(profile: profile, apiKey: keychain.secret(for: id) ?? "")
    }
}
