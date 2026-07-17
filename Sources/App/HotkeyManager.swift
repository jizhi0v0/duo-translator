import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let translateSelection = Self("translateSelection", default: .init(.d, modifiers: [.option]))
    static let openInputWindow = Self("openInputWindow", default: .init(.a, modifiers: [.option]))
    static let ocrTranslate = Self("ocrTranslate", default: .init(.s, modifiers: [.option]))
    static let ocrToInput = Self("ocrToInput", default: .init(.s, modifiers: [.option, .shift]))
}

@MainActor
final class HotkeyManager {
    init(coordinator: AppCoordinator) {
        KeyboardShortcuts.onKeyUp(for: .translateSelection) { [weak coordinator] in
            coordinator?.translateSelection()
        }
        KeyboardShortcuts.onKeyUp(for: .openInputWindow) { [weak coordinator] in
            coordinator?.openInputWindow()
        }
        KeyboardShortcuts.onKeyUp(for: .ocrTranslate) { [weak coordinator] in
            coordinator?.ocrTranslate()
        }
        KeyboardShortcuts.onKeyUp(for: .ocrToInput) { [weak coordinator] in
            coordinator?.ocrToInput()
        }
    }
}
