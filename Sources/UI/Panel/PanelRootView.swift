import SwiftUI

/// Bob-style panel layout: toolbar on top, input editor, language bar in the
/// middle, stacked engine result cards below.
struct PanelRootView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onContentHeightChange: (CGFloat) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelToolbarView(viewModel: viewModel)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 6)

            if let notice = viewModel.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            InputSectionView(viewModel: viewModel, run: run)
                .padding(.horizontal, 12)

            LanguageBarView(viewModel: viewModel)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

            Divider()

            ResultListView(
                viewModel: viewModel,
                run: run,
                onResultsHeightChange: onContentHeightChange
            )
        }
        .frame(minWidth: 380, minHeight: 260)
        .background(AppleTranslationHostView())
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}
