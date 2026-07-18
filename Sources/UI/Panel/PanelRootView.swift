import SwiftUI

/// Bob-style panel layout: toolbar on top, input editor, language bar in the
/// middle, stacked engine result cards below.
struct PanelRootView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onContentHeightChange: (CGFloat) -> Void
    /// Measured height of everything above the result list (toolbar, input,
    /// language bar, divider). Reported so the window fits exactly instead of
    /// relying on a fixed estimate that leaves a gap when the input is short.
    var onChromeHeightChange: (CGFloat) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelToolbarView(viewModel: viewModel, onClose: onClose)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                InputSectionView(viewModel: viewModel, run: run)
                    .padding(.horizontal, 12)

                LanguageBarView(viewModel: viewModel)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                Divider()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                onChromeHeightChange($0)
            }

            ResultListView(
                viewModel: viewModel,
                run: run,
                onResultsHeightChange: onContentHeightChange
            )

            // Absorbs any window height beyond the content so the result area
            // keeps its intrinsic size (reliable measurement) and extra space
            // sits at the bottom, never as a gap above the toolbar.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 380, minHeight: 220)
        .background(AppleTranslationHostView())
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        // Notice floats as a toast so showing/hiding it never changes the
        // measured height (and thus never resizes the window).
        .overlay(alignment: .bottom) {
            if let notice = viewModel.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15)))
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
    }
}
