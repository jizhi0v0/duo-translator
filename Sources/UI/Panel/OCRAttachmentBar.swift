import SwiftUI

/// The OCR image attachment shown at the top of the input box, like a chat
/// composer's attached image: a thumbnail with a remove button, plus recognition
/// status / actions for the empty & failed states and a 重新识别 button. Observes
/// the session so status and the 重新识别 affordance track the recognition phase.
struct OCRAttachmentBar: View {
    @ObservedObject var session: OCRSession
    /// Drop the attachment (clears the session → back to a plain input box).
    var onRemove: () -> Void

    private static let thumbMaxWidth: CGFloat = 120
    private static let thumbMaxHeight: CGFloat = 64

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            status
            Spacer(minLength: 0)
        }
    }

    private var thumbnail: some View {
        Image(nsImage: session.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: Self.thumbMaxWidth, maxHeight: Self.thumbMaxHeight, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            // Tap the image (not a Button, to avoid nesting with the × button) to
            // open the full-size viewer.
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { session.onView?() }
            .help("点击查看大图")
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("移除截图")
                .offset(x: 5, y: -5)
            }
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .recognizing:
            // The "识别中…" text lives in the editor placeholder; nothing here.
            EmptyView()
        case .done:
            reRecognizeButton
        case .empty:
            statusColumn(message: "没有识别到文字。")
        case .failed(let message):
            statusColumn(message: message)
        }
    }

    private func statusColumn(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let action = session.action {
                    Button(action.title) { action.handler() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                reRecognizeButton
            }
        }
    }

    private var reRecognizeButton: some View {
        Button {
            session.reRecognize?()
        } label: {
            Label("重新识别", systemImage: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("在同一张截图上重新识别")
        .accessibilityIdentifier("ocr.reRecognize")
    }
}

/// The "识别中…" placeholder overlaid on the empty input editor while recognition
/// runs. A separate view so it observes the session and clears the instant the
/// phase leaves `.recognizing`.
struct OCRRecognizingLabel: View {
    @ObservedObject var session: OCRSession

    var body: some View {
        if session.phase == .recognizing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("识别中…")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
