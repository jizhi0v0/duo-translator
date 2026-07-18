import SwiftUI

/// Vertically stacked result cards, one per enabled engine, inside a scroll
/// view. Reports the stack's total height so the window can grow to fit
/// (scrolling once the growth ceiling is reached).
struct ResultListView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onResultsHeightChange: (CGFloat) -> Void

    var body: some View {
        if run.runs.isEmpty {
            VStack {
                Spacer()
                Text("回车翻译，Shift+回车换行")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(run.runs) { engineRun in
                        ResultCardView(
                            engineRun: engineRun,
                            isCollapsed: viewModel.collapsedBinding(for: engineRun.id),
                            targetLanguage: run.targetLanguage,
                            onRetry: { run.retry(runID: engineRun.id) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    onResultsHeightChange($0)
                }
            }
        }
    }
}
