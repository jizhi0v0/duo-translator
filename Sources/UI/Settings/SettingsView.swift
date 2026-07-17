import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            HotkeySettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 560)
        .padding(.bottom)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Text("引擎与语言设置将在后续里程碑加入。")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("划词翻译", name: .translateSelection)
            KeyboardShortcuts.Recorder("输入翻译", name: .openInputWindow)
            KeyboardShortcuts.Recorder("截图翻译", name: .ocrTranslate)
            KeyboardShortcuts.Recorder("截图取字", name: .ocrToInput)
        }
        .padding()
    }
}
