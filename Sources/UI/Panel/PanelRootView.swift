import SwiftUI

struct PanelRootView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    var onContentHeightChange: (CGFloat) -> Void
    var onClose: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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

            inputEditor
                .padding(.horizontal, 12)

            Divider()
                .padding(.top, 8)

            resultArea
        }
        .frame(minWidth: 380, minHeight: 260)
        .background(AppleTranslationHostView())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(viewModel.languageBadge)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.copySelectedResult()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制译文")
            Button {
                viewModel.isPinned.toggle()
            } label: {
                Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(viewModel.isPinned ? "取消固定" : "固定窗口（点击其他区域不关闭）")
        }
        .padding(.top, 16) // keep clear of the traffic-light close button
    }

    private var inputEditor: some View {
        TextEditor(text: $viewModel.inputText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
            .frame(minHeight: 64, maxHeight: 110)
            .focused($inputFocused)
            .onKeyPress { press in
                guard press.key == .return, !press.modifiers.contains(.shift) else {
                    return .ignored
                }
                viewModel.translate()
                return .handled
            }
            .onChange(of: viewModel.focusToken) {
                inputFocused = true
            }
            .onAppear {
                inputFocused = true
            }
    }

    @ViewBuilder
    private var resultArea: some View {
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
            VStack(spacing: 0) {
                if run.runs.count > 1 {
                    Picker("引擎", selection: $run.selectedRunID) {
                        ForEach(run.runs) { engineRun in
                            Text(engineRun.name).tag(Optional(engineRun.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                ZStack {
                    ForEach(run.runs) { engineRun in
                        EngineResultView(
                            engineRun: engineRun,
                            onContentHeightChange: engineRun.id == selectedID ? onContentHeightChange : nil
                        )
                        .opacity(engineRun.id == selectedID ? 1 : 0)
                        .allowsHitTesting(engineRun.id == selectedID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedID: String? {
        run.selectedRunID ?? run.runs.first?.id
    }
}

struct EngineResultView: View {
    @ObservedObject var engineRun: EngineRunModel
    var onContentHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            StreamingTextView(
                model: engineRun.stream,
                onContentHeightChange: onContentHeightChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 6) {
            switch engineRun.state {
            case .streaming:
                ProgressView()
                    .controlSize(.small)
                Text("\(engineRun.name) 翻译中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .done(let seconds):
                Text("\(engineRun.name) · \(String(format: "%.1f", seconds))s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
