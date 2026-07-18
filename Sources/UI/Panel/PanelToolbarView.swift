import SwiftUI

/// Top toolbar row: pin on the left (clear of the traffic-light close
/// button), quick actions on the right.
struct PanelToolbarView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    viewModel.isPinned.toggle()
                } label: {
                    Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.glass)
                .help(viewModel.isPinned ? "取消固定" : "固定窗口（点击其他区域不关闭）")

                Spacer()

                Button {
                    viewModel.copyFirstResult()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .help("复制首个完成的译文")
            }
        }
        .padding(.leading, 18) // keep clear of the traffic-light close button
        .padding(.top, 4)
    }
}
