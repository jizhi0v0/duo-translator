import SwiftUI

/// The link "chip" shown at the top of the input box for 链接翻译, mirroring the
/// OCR image attachment: a link glyph with the article title + host, the live
/// fetch status (抓取中… / 失败), a remove button, and a 重新抓取 action. Observes
/// the session so status tracks the fetch phase.
struct LinkAttachmentBar: View {
    @ObservedObject var session: LinkSession
    /// Drop the attachment (clears the session → back to a plain input box).
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title?.isEmpty == false ? session.title! : session.host)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.host)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                status
            }

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary, .clear)
            }
            .buttonStyle(.plain)
            .help("移除链接")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .fetching:
            // The "抓取正文中…" spinner lives in the editor placeholder; showing
            // one here too would double it up.
            EmptyView()
        case .done:
            EmptyView()
        case .empty:
            statusRow(message: "没能提取到正文。")
        case .failed(let message):
            statusRow(message: message)
        }
    }

    private func statusRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let action = session.action {
                    Button(action.title) { action.handler() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                reFetchButton
            }
        }
        .padding(.top, 1)
    }

    private var reFetchButton: some View {
        Button {
            session.reFetch?()
        } label: {
            Label("重新抓取", systemImage: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("重新抓取这个链接的正文")
        .accessibilityIdentifier("link.reFetch")
    }
}
