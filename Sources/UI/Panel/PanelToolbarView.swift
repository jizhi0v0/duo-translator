import SwiftUI

/// Top toolbar row. The panel hides the native traffic-light buttons, so this
/// row owns the whole width: pin on the left (truly left-aligned now), close on
/// the right. Copy lives on each result card, so there's no copy action here.
struct PanelToolbarView: View {
    @ObservedObject var viewModel: PanelViewModel
    var onClose: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    viewModel.isPinned.toggle()
                } label: {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .help(viewModel.isPinned ? "取消固定" : "固定窗口（点击其他区域不关闭）")

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .help("关闭（Esc）")
            }
        }
    }
}
