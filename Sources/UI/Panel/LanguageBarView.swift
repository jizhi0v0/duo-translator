import SwiftUI

/// Language bar: source on the left, target on the right, the swap button
/// exactly centered between them. There's no re-translate button — changing a
/// language or swapping re-runs the translation immediately.
struct LanguageBarView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        // Swap fixed at the panel center; each language centered within its own
        // half (the space left / right of the swap).
        HStack(spacing: 6) {
            languageMenu(selection: $viewModel.selectedSource, emptyLabel: "自动检测")
                .frame(maxWidth: .infinity)

            Button {
                viewModel.swapLanguages()
                viewModel.retranslate()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("互换源/目标语言")

            languageMenu(selection: $viewModel.selectedTarget, emptyLabel: "自动选择")
                .frame(maxWidth: .infinity)
        }
        .font(.caption)
    }

    private func languageMenu(selection: Binding<String>, emptyLabel: String) -> some View {
        Menu {
            ForEach(viewModel.languageOptions(including: selection.wrappedValue), id: \.self) { code in
                Button(LanguagePolicy.localizedName(for: code)) {
                    selection.wrappedValue = code
                    viewModel.retranslate() // apply immediately, no button
                }
            }
        } label: {
            Text(selection.wrappedValue.isEmpty ? emptyLabel : LanguagePolicy.localizedName(for: selection.wrappedValue))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
