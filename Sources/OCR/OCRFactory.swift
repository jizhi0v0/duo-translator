import Vision

/// Resolves the persisted OCR selection into a live provider. Apple Vision is
/// the default and the fallback: any selection that no longer resolves to an
/// existing OCR-capable provider (deleted provider, or a non-vision kind)
/// quietly reverts to Apple, so OCR never breaks because a provider changed.
@MainActor
enum OCRFactory {
    static func makeProvider(settings: SettingsStore, keychain: KeychainStore) -> OCRProvider {
        let level: VNRequestTextRecognitionLevel = settings.ocrVisionLevel == "fast" ? .fast : .accurate
        let apple = AppleVisionOCRProvider(
            languages: settings.ocrLanguages,
            mergeParagraphs: settings.ocrMergesLines,
            level: level
        )

        // Empty selection, a stale id, an Apple provider, or any non-vision kind
        // all mean "use the built-in Vision path".
        guard let id = UUID(uuidString: settings.ocrProviderID),
              let provider = settings.provider(id: id),
              provider.kind.isLLM else {
            return apple
        }
        let profile = EngineProfile(provider: provider, model: settings.ocrModel)
        return LLMVisionOCRProvider(profile: profile, apiKey: keychain.secret(for: provider.id) ?? "")
    }
}
