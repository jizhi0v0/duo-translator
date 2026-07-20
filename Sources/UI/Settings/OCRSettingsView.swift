import SwiftUI

struct OCRSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Vision recognition language options.
    private static let choices: [String] = [
        "zh-Hans", "zh-Hant", "en-US", "ja", "ko", "fr-FR", "de-DE", "es-ES", "ru-RU", "pt-BR", "it-IT",
    ]

    /// Vision-capable engines the user has configured, offered as OCR backends.
    private var llmProfiles: [EngineProfile] {
        settings.engineProfiles.filter { $0.kind.isLLM }
    }

    private var isApple: Bool { settings.ocrProvider == OCRFactory.appleSelection }

    /// The selected LLM engine, when one is chosen (nil for Apple or a stale id).
    private var selectedLLM: EngineProfile? {
        guard !isApple, let id = UUID(uuidString: settings.ocrProvider) else { return nil }
        return llmProfiles.first { $0.id == id }
    }

    var body: some View {
        Form {
            Section("识别引擎") {
                Picker("引擎", selection: $settings.ocrProvider) {
                    Label("Apple 内置（离线免费）", systemImage: "apple.logo")
                        .tag(OCRFactory.appleSelection)
                    ForEach(llmProfiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
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

    /// Config feedback for the selected vision LLM: reuse the engine list's
    /// shared check so the warning wording matches the 引擎 page exactly.
    @ViewBuilder private var llmStatus: some View {
        if let profile = selectedLLM {
            if let issue = engineConfigIssue(profile) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                Label("将用「\(profile.name)」的视觉模型识别截图。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Text("需选用支持图像的模型（如 gpt-4o、Claude）。在「引擎」页配置 key、模型并用「连接测试」验证。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// If the persisted selection points at an engine that's gone (or never was
    /// an LLM), snap the picker back to Apple so the UI matches the factory's
    /// fallback instead of showing a blank Picker row.
    private func normalizeSelection() {
        guard !isApple, selectedLLM == nil else { return }
        settings.ocrProvider = OCRFactory.appleSelection
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
