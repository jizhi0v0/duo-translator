import SwiftUI

struct OCRSettingsView: View {
    @ObservedObject var settings: SettingsStore

    /// Vision recognition language options.
    private static let choices: [String] = [
        "zh-Hans", "zh-Hant", "en-US", "ja", "ko", "fr-FR", "de-DE", "es-ES", "ru-RU", "pt-BR", "it-IT",
    ]

    var body: some View {
        Form {
            Section("识别语言（排在前面的优先）") {
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
        .formStyle(.grouped)
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
