import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("语言") {
                Picker("语言 A（母语）", selection: $settings.firstLanguage) {
                    ForEach(SettingsStore.languageChoices, id: \.self) { code in
                        Text(LanguagePolicy.localizedName(for: code)).tag(code)
                    }
                }
                Picker("语言 B", selection: $settings.secondLanguage) {
                    ForEach(SettingsStore.languageChoices, id: \.self) { code in
                        Text(LanguagePolicy.localizedName(for: code)).tag(code)
                    }
                }
                Text("检测到语言 A 的文本会翻译成语言 B，其余翻译成语言 A。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
