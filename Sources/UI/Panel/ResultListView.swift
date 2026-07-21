import SwiftUI

/// Vertically stacked result cards, one per enabled engine. The stack is
/// intrinsically sized so its measured height is reliable and the window fits it
/// exactly. Each card's body follows its streamed text up to its share of the
/// window (`perCardMaxBody`), then scrolls internally (its own NSScrollView)
/// rather than pushing later cards out of the panel.
struct ResultListView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onResultsHeightChange: (CGFloat) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                onResultsHeightChange($0)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.ocrRecognizing {
            // Recognizing: nothing to translate yet. Render nothing so the result
            // area collapses (no reserved hint height under the input).
            Color.clear.frame(height: 0)
        } else if run.runs.isEmpty {
            // Keep the placeholder's footprint stable, but hide its text while a
            // notice toast floats over this same spot (they'd overlap).
            Text("回车翻译，Shift+回车换行")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .opacity(viewModel.notice == nil ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 8) {
                ForEach(run.runs) { engineRun in
                    ResultCardView(
                        engineRun: engineRun,
                        isCollapsed: viewModel.collapsedBinding(for: engineRun.id),
                        metricsPresented: viewModel.metricsPopoverBinding(for: engineRun.id),
                        targetLanguage: run.targetLanguage,
                        maxBodyHeight: perCardMaxBody,
                        onRetry: { run.retry(runID: engineRun.id) },
                        onDownloadApple: { source, target in
                            run.downloadAppleLanguagePack(
                                runID: engineRun.id, source: source, target: target
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// Per-card body ceiling, shrinking as more providers share the window so
    /// every card's header/footer stays visible (each body scrolls internally)
    /// rather than the whole stack overflowing the window.
    private var perCardMaxBody: CGFloat {
        // Budget is the live result-area height (window ceiling − chrome),
        // published by the panel, minus this view's own vertical padding (10+10).
        // So the cards shrink when the input/chrome is tall and the total always
        // fits — never pushing the bottom card off-screen with no scrollbar.
        PanelLayout.perCardBodyMax(
            count: run.runs.count,
            budget: viewModel.resultAreaBudget - 20,
            cardChrome: Self.cardChrome,
            floor: 96
        )
    }

    /// Header + divider/grab band + footer around each card's body.
    private static let cardChrome: CGFloat = 90
}
