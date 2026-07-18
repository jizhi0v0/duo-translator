import SwiftUI

/// The input editor with a footer row (speak / copy of the source text) styled
/// to match the result cards — a divider above a leading row of actions.
struct InputSectionView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    @ObservedObject private var speech = SpeechService.shared

    @FocusState private var inputFocused: Bool

    /// Fixed input height — a stable, proportioned box (longer text scrolls
    /// inside it, keeping line breaks). The user preferred this over an
    /// auto-growing editor for a clearer visual hierarchy.
    private static let editorHeight: CGFloat = 125
    private static let font = Font.system(size: 13)

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $viewModel.inputText)
                .font(Self.font)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: Self.editorHeight)
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

            Divider().padding(.horizontal, 10)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                speech.toggle(
                    id: "input",
                    text: viewModel.inputText,
                    languageCode: run.detectedLanguage
                )
            } label: {
                Image(systemName: speech.speakingID == "input" ? "stop.fill" : "speaker.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(speech.speakingID == "input" ? "停止朗读" : "朗读原文")
            .disabled(viewModel.inputText.isEmpty)

            Button {
                let text = viewModel.inputText
                guard !text.isEmpty else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("复制原文")
            .disabled(viewModel.inputText.isEmpty)

            Spacer()

            Label("回车翻译", systemImage: "return")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("在输入框按回车即可翻译")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 7)
    }
}
