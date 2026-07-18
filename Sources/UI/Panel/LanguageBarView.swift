import SwiftUI

/// Source ⇄ target language menus with swap and re-translate, sitting between
/// the input editor and the result cards (Bob-style). Selections are
/// temporary; changing them does nothing until re-translate is pressed.
struct LanguageBarView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        HStack(spacing: 6) {
            languageMenu(selection: $viewModel.selectedSource, emptyLabel: "自动检测")

            Button {
                viewModel.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("互换源/目标语言")

            languageMenu(selection: $viewModel.selectedTarget, emptyLabel: "自动选择")

            Spacer()

            Button {
                viewModel.retranslate()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新翻译（会打断当前请求）")
            .disabled(viewModel.selectedTarget.isEmpty)
        }
        .font(.caption)
    }

    private func languageMenu(selection: Binding<String>, emptyLabel: String) -> some View {
        Menu {
            ForEach(viewModel.languageOptions(including: selection.wrappedValue), id: \.self) { code in
                Button(LanguagePolicy.localizedName(for: code)) { selection.wrappedValue = code }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? emptyLabel : LanguagePolicy.localizedName(for: selection.wrappedValue))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
