import SwiftUI

/// Top toolbar row. The panel hides the native traffic-light buttons, so this
/// row owns the whole width: pin on the left, close on the right. Copy lives on
/// each result card, so there's no copy action here.
///
/// Both buttons share one subtle circular icon style so they read as a matched
/// pair — equal size and weight — instead of the mismatched, over-heavy glass
/// boxes they used to be.
struct PanelToolbarView: View {
    @ObservedObject var viewModel: PanelViewModel
    /// Whether there are results to show — gates the page-mode toggle.
    var hasResults: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ToolbarIconButton(
                systemName: viewModel.isPinned ? "pin.fill" : "pin",
                isActive: viewModel.isPinned,
                help: viewModel.isPinned ? "取消固定" : "固定窗口（点击其他区域不关闭）"
            ) {
                viewModel.isPinned.toggle()
            }
            .accessibilityIdentifier("toolbar.pin")

            if hasResults {
                ToolbarIconButton(
                    systemName: "rectangle.split.2x1",
                    isActive: viewModel.pageMode,
                    help: viewModel.pageMode ? "退出页面模式" : "页面模式（大视图 / 双语对照）"
                ) {
                    viewModel.togglePageMode()
                }
                .accessibilityIdentifier("toolbar.pageMode")
            }

            Spacer()

            ToolbarIconButton(
                systemName: "xmark",
                hoverTint: .red,
                help: "关闭（Esc）"
            ) {
                onClose()
            }
            .accessibilityIdentifier("toolbar.close")
        }
    }
}

/// A compact, borderless circular icon button for the panel toolbar. Idle it's
/// a bare glyph; on hover a soft filled circle appears behind it. `isActive`
/// (e.g. pin engaged) tints the glyph with the accent color and shows a faint
/// resting fill so the state is legible without hovering. `hoverTint` lets the
/// close button glow red on hover, matching the platform's close affordance.
private struct ToolbarIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var hoverTint: Color? = nil
    let help: String
    let action: () -> Void

    @State private var hovering = false

    private var glyphColor: Color {
        if hovering, let hoverTint { return hoverTint }
        return isActive ? .accentColor : .secondary
    }

    private var fillOpacity: Double {
        if hovering { return 0.16 }
        return isActive ? 0.10 : 0
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill((hoverTint ?? .secondary).opacity(fillOpacity))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }
}
