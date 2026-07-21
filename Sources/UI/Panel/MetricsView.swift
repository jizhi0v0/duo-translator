import SwiftUI

/// Anchor of the header gauge whose metrics readout is open, published up to
/// `PanelRootView` so the floating card can be positioned next to it. Only the
/// active gauge contributes a non-nil value.
struct MetricsAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Floating performance-readout card for one LLM run: a titled card with two
/// headline stat tiles (first-token latency and output throughput) over a
/// compact detail list of total time and token usage.
///
/// Rendered as an in-window overlay (see `PanelRootView`), NOT a `.popover`: a
/// SwiftUI popover is its own window, and on the non-activating panel its
/// teardown races the page-mode resize and flashes the panel. An overlay has no
/// window, so mode switches stay clean.
struct MetricsPopover: View {
    let metrics: RunMetrics
    let engineName: String
    let kind: ProviderKind
    /// Model the profile asked for, so a provider that routed elsewhere can be
    /// called out. Empty for engines without a configurable model.
    var requestedModel: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                EngineIcon(kind: kind)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(engineName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let ttft = metrics.ttftDisplay {
                    StatTile(caption: "首 Token", value: ttft.value, unit: ttft.unit)
                }
                if let speed = metrics.speedDisplay {
                    StatTile(caption: "输出速度", value: speed.value, unit: speed.unit)
                }
            }

            Divider()

            VStack(spacing: 7) {
                DetailRow(label: "总耗时", value: metrics.totalDisplay.value + " " + metrics.totalDisplay.unit)
                if let flow = metrics.tokenFlow {
                    DetailRow(label: "Token", value: flow)
                }
                if let total = metrics.totalTokens {
                    DetailRow(label: "合计 Token", value: "\(total)")
                }
                if metrics.completionTokens == nil {
                    DetailRow(label: "输出", value: "\(metrics.outputChars) 字")
                }
                if let cost = metrics.costDisplay {
                    DetailRow(label: "成本", value: cost)
                }
                // The rest only appear when they have something to say: a
                // reasoning model, a cache hit, a stall, a re-route. On an
                // ordinary run the card stays as short as it was.
                if let reasoning = metrics.reasoningDisplay {
                    DetailRow(label: "思考 Token", value: reasoning)
                }
                if let cache = metrics.cacheDisplay {
                    DetailRow(label: "缓存命中", value: cache)
                }
                if let network = metrics.networkDisplay {
                    DetailRow(label: "连接", value: network)
                }
                if let stall = metrics.stallDisplay {
                    DetailRow(label: "流式", value: stall)
                }
                if let routed = metrics.routedModelDisplay(requested: requestedModel) {
                    DetailRow(label: "实际模型", value: routed)
                }
            }
        }
        .padding(14)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
    }
}

/// A headline number: small caption on top, large monospaced value with a
/// muted unit below. Fills its share of the row so two tiles sit evenly.
private struct StatTile: View {
    let caption: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

/// A label/value line in the detail list: muted label left, aligned value right.
private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}
