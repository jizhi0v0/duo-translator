import SwiftUI
import KeyboardShortcuts

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

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            Section("全局快捷键") {
                KeyboardShortcuts.Recorder("划词翻译", name: .translateSelection)
                KeyboardShortcuts.Recorder("输入翻译", name: .openInputWindow)
                KeyboardShortcuts.Recorder("截图翻译", name: .ocrTranslate)
                KeyboardShortcuts.Recorder("截图取字", name: .ocrToInput)
            }
        }
        .formStyle(.grouped)
    }
}
