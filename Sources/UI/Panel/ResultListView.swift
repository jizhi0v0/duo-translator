import SwiftUI

/// Vertically stacked result cards, one per enabled engine. Uses a plain VStack
/// (no outer ScrollView): the stack is intrinsically sized, so its measured
/// height is reliable and the window fits it exactly. Each card body scrolls
/// internally (its own NSScrollView) once it hits `perCardMaxBody`, so long
/// output never forces the stack itself to scroll and push titles off-screen.
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
        if run.runs.isEmpty {
            Text("回车翻译，Shift+回车换行")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 8) {
                ForEach(run.runs) { engineRun in
                    ResultCardView(
                        engineRun: engineRun,
                        isCollapsed: viewModel.collapsedBinding(for: engineRun.id),
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
        let count = max(run.runs.count, 1)
        // Usable result-area height at the window's growth ceiling, minus each
        // card's own header/footer overhead, split evenly across the cards.
        let resultBudget: CGFloat = 480
        let cardChrome: CGFloat = 82
        return max(150, (resultBudget - CGFloat(count) * cardChrome) / CGFloat(count))
    }
}
