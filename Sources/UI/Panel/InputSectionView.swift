import SwiftUI

/// The input editor with its accessory row: detected-language badge plus
/// speak / copy actions for the source text.
struct InputSectionView: View {
    @ObservedObject var viewModel: PanelViewModel
    @ObservedObject var run: TranslationRunController
    @ObservedObject private var speech = SpeechService.shared

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $viewModel.inputText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
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

            accessoryRow
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

    private var accessoryRow: some View {
        HStack(spacing: 10) {
            if let detected = run.detectedLanguage {
                Text("识别为 \(LanguagePolicy.localizedName(for: detected))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            Spacer()

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
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}
