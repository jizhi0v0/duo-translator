import SwiftUI

struct OCRSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Sentinel picker tag for the built-in Apple Vision path (stored as an
    /// empty `ocrProviderID`).
    private static let appleTag = ""

    /// Vision recognition language options.
    private static let choices: [String] = [
        "zh-Hans", "zh-Hant", "en-US", "ja", "ko", "fr-FR", "de-DE", "es-ES", "ru-RU", "pt-BR", "it-IT",
    ]

    /// Vision-capable providers offered as LLM OCR backends.
    private var llmProviders: [Provider] {
        settings.providers.filter { $0.kind.isLLM }
    }

    private var isApple: Bool { selectedProvider == nil }

    /// The selected LLM provider, when one is chosen (nil for Apple or a stale id).
    private var selectedProvider: Provider? {
        guard let id = UUID(uuidString: settings.ocrProviderID) else { return nil }
        return llmProviders.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section("识别引擎") {
                Picker("引擎", selection: $settings.ocrProviderID) {
                    Label("Apple 内置（离线免费）", systemImage: "apple.logo")
                        .tag(Self.appleTag)
                    ForEach(llmProviders) { provider in
                        Text(provider.name).tag(provider.id.uuidString)
                    }
                }

                if isApple {
                    Picker("精度", selection: $settings.ocrVisionLevel) {
                        Text("精确").tag("accurate")
                        Text("快速").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    Text("精确：神经网络识别 + 语言校正，更准。快速：更省时，适合清晰印刷体。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("视觉模型", text: $settings.ocrModel)
                        .autocorrectionDisabled()
                    llmStatus
                }
            }

            if isApple {
                Section("识别语言（排在前面的优先）") {
                    if settings.ocrLanguages.isEmpty {
                        Label("至少选择一种语言，否则截图 OCR 无法识别文字。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    ForEach(Self.choices, id: \.self) { code in
                        Toggle(
                            LanguagePolicy.localizedName(for: code),
                            isOn: binding(for: code)
                        )
                    }
                }
                Section("排版") {
                    Toggle("合并断行为段落", isOn: $settings.ocrMergesLines)
                    Text("开启后按行距拼段落：中日韩相邻行直接连接，拉丁文行以空格连接。关闭则按识别行输出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: normalizeSelection)
    }

    /// Config feedback for the selected vision provider: reuse the shared
    /// connection check so the warning wording matches the 供应商 page, and flag
    /// a missing model (which is OCR-specific, not a provider issue).
    @ViewBuilder private var llmStatus: some View {
        if let provider = selectedProvider {
            if let issue = providerConfigIssue(provider) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if settings.ocrModel.isEmpty {
                Label("请填写视觉模型（如 gpt-4o、claude-…）。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Label("将用「\(provider.name)」的 \(settings.ocrModel) 识别截图。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Text("需选用支持图像的模型（如 gpt-4o、Claude）。在「供应商」页配置 key、Base URL 并保证连接可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// If the persisted selection points at a provider that's gone (or never was
    /// an LLM), snap the picker back to Apple so the UI matches the factory's
    /// fallback instead of showing a blank Picker row.
    private func normalizeSelection() {
        guard !isApple, selectedProvider == nil else { return }
        settings.ocrProviderID = Self.appleTag
    }

    private func binding(for code: String) -> Binding<Bool> {
        Binding(
            get: { settings.ocrLanguages.contains(code) },
            set: { enabled in
                if enabled {
                    if !settings.ocrLanguages.contains(code) {
                        settings.ocrLanguages.append(code)
                    }
                } else {
                    settings.ocrLanguages.removeAll { $0 == code }
                }
            }
        )
    }
}
