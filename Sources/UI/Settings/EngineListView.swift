import SwiftUI

/// Translation result cards: one row per `TranslationConfig` (icon + name +
/// enable toggle), click to edit, drag to reorder. Each card references a
/// `Provider` (connection) and picks its own model. The list order is the array
/// order in `SettingsStore.translationConfigs`, which also determines the order
/// of the result cards in the translation panel.
struct EngineListView: View {
    @ObservedObject var settings: SettingsStore
    /// Which card's detail is open, or nil for the list. Navigation is driven by
    /// hand rather than `NavigationStack` (see the settings tab controller owns
    /// the toolbar area, leaving a back button nowhere to render).
    @State private var selectedID: UUID?

    var body: some View {
        Group {
            if let id = selectedID,
               let index = settings.translationConfigs.firstIndex(where: { $0.id == id }) {
                detail(index: index)
            } else {
                listPane
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if settings.translationConfigs.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($settings.translationConfigs) { $config in
                        row($config)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = config.id }
                            .contextMenu {
                                Button("删除", role: .destructive) { remove(id: config.id) }
                            }
                    }
                    .onMove { from, to in
                        settings.translationConfigs.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            bottomBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("还没有翻译卡片")
                .foregroundStyle(.secondary)
            Text(settings.providers.isEmpty ? "请先在「供应商」添加一个供应商" : "点左下角 + 用某个供应商添加卡片")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    selectedID = nil
                } label: {
                    Label("卡片", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(settings.translationConfigs[index].name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(role: .destructive) {
                    let id = settings.translationConfigs[index].id
                    selectedID = nil
                    remove(id: id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("删除此卡片")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            TranslationConfigDetailView(settings: settings, config: $settings.translationConfigs[index])
        }
    }

    private func row(_ config: Binding<TranslationConfig>) -> some View {
        let c = config.wrappedValue
        let provider = settings.provider(id: c.providerID)
        return HStack(spacing: 10) {
            Group {
                if let provider {
                    EngineIcon(kind: provider.kind, size: 18)
                        .foregroundStyle(c.enabled ? Color.accentColor : Color.secondary)
                } else {
                    Image(systemName: "questionmark.circle").resizable().scaledToFit().frame(width: 18, height: 18)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name)
                Text(subtitle(config: c, provider: provider))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if c.enabled, let issue = translationConfigIssue(config: c, provider: provider) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(issue)
            }
            Spacer()
            Toggle("", isOn: config.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private func subtitle(config: TranslationConfig, provider: Provider?) -> String {
        guard let provider else { return "供应商已删除" }
        if provider.kind.isLLM, !config.model.isEmpty {
            return "\(provider.name) · \(config.model)"
        }
        return provider.name
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                if settings.providers.isEmpty {
                    Text("请先在「供应商」添加供应商")
                } else {
                    ForEach(settings.providers) { provider in
                        Button {
                            addCard(provider: provider)
                        } label: {
                            Label(provider.name, systemImage: "plus")
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("添加翻译卡片")

            Spacer()

            Text("点按编辑 · 拖动排序（即卡片顺序）· 右键删除")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
    }

    private func addCard(provider: Provider) {
        let config = TranslationConfig(
            providerID: provider.id,
            name: provider.name,
            model: provider.defaultModel
        )
        settings.translationConfigs.append(config)
        selectedID = config.id
    }

    private func remove(id: UUID) {
        settings.translationConfigs.removeAll { $0.id == id }
        settings.clearResultBodyHeight(for: id.uuidString)
    }
}

/// The first thing keeping this translation card from running, or nil when it's
/// ready. Shared by the list warning badge and the detail-view status line.
@MainActor
func translationConfigIssue(config: TranslationConfig, provider: Provider?) -> String? {
    guard let provider else { return "供应商已删除，请重新选择" }
    if let issue = providerConfigIssue(provider) { return issue }
    if provider.kind.isLLM, config.model.isEmpty { return "缺少模型" }
    return nil
}

/// The first thing keeping this provider from connecting, or nil when its
/// connection is complete. Model is per-feature, so it is not checked here.
@MainActor
func providerConfigIssue(_ provider: Provider) -> String? {
    switch provider.kind {
    case .apple:
        return nil
    case .deepL:
        return KeychainStore.shared.hasSecret(for: provider.id) ? nil : "未配置 API Key"
    case .openAICompat, .anthropic:
        if provider.baseURL.isEmpty { return "缺少 Base URL" }
        if !KeychainStore.shared.hasSecret(for: provider.id) { return "未配置 API Key" }
        return nil
    }
}

/// Numeric entry for a per-million-token price. Empty reads as 0, i.e. unknown.
struct PriceField: View {
    @Binding var value: Double

    var body: some View {
        TextField("0", value: $value, format: .number.precision(.fractionLength(0...4)))
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
    }
}

extension ProviderKind {
    /// Bundled monochrome brand logo (Media.xcassets, template-rendered), or nil
    /// to fall back to `symbolName`. Apple uses its official SF Symbol glyph, so
    /// no asset is bundled for it.
    var logoAssetName: String? {
        switch self {
        case .openAICompat: return "openai"
        case .anthropic: return "anthropic"
        case .deepL: return "deepl"
        case .apple: return nil
        }
    }

    /// SF Symbol fallback, used when no bundled logo exists (Apple) or an asset
    /// is missing.
    var symbolName: String {
        switch self {
        case .apple: return "apple.logo"
        case .openAICompat: return "sparkles"
        case .anthropic: return "brain"
        case .deepL: return "network"
        }
    }
}

/// The provider's mark, tintable via `foregroundStyle` in both the result cards
/// and the settings lists: a bundled brand logo where we have one, else the SF
/// Symbol fallback. Sizes itself to a square so the two render interchangeably.
struct EngineIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let asset = kind.logoAssetName {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: kind.symbolName).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Editor for one translation card: which provider, model, prompt, pricing —
/// plus a live connection test that runs the exact resolved engine.
struct TranslationConfigDetailView: View {
    @ObservedObject var settings: SettingsStore
    @Binding var config: TranslationConfig
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    private var provider: Provider? { settings.provider(id: config.providerID) }
    private var isLLM: Bool { provider?.kind.isLLM ?? false }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $config.name)
                Toggle("启用", isOn: $config.enabled)
            }

            Section("供应商") {
                if settings.providers.isEmpty {
                    Label("请先在「供应商」页添加一个供应商。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Picker("供应商", selection: $config.providerID) {
                        ForEach(settings.providers) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }
            }

            if isLLM {
                Section("模型") {
                    TextField("模型", text: $config.model)
                        .autocorrectionDisabled()
                }

                // Prices are per model and change often, so they are entered
                // rather than baked in: a stale built-in table would report
                // confident, wrong costs. Left at 0, the readout omits cost.
                Section("价格（每百万 Token，留空则不显示成本）") {
                    LabeledContent("输入") { PriceField(value: $config.inputPricePerMTok) }
                    LabeledContent("输出") { PriceField(value: $config.outputPricePerMTok) }
                    LabeledContent("缓存输入") { PriceField(value: $config.cachedInputPricePerMTok) }
                }

                Section("系统提示词（{{target}} 会替换为目标语言）") {
                    TextEditor(text: $config.systemPromptTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 90)
                }
            }

            testSection
        }
        .formStyle(.grouped)
    }

    /// Lets the user confirm the card actually works before relying on it,
    /// instead of discovering a bad key/URL/model only at translate time. Runs
    /// one real request through the same factory the app uses.
    @ViewBuilder private var testSection: some View {
        Section("连接测试") {
            if let issue = translationConfigIssue(config: config, provider: provider) {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Button {
                    runTest()
                } label: {
                    if test == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(test == .running || provider == nil)

                switch test {
                case .success:
                    Label("连接成功", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                case .failure:
                    Label("连接失败", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                case .idle, .running:
                    EmptyView()
                }
            }

            switch test {
            case .success(let text):
                Text("译文：\(text)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .failure(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .idle, .running:
                EmptyView()
            }
        }
    }

    private func runTest() {
        guard let provider else { return }
        test = .running
        let profile = EngineProfile(provider: provider, config: config)
        let target = settings.firstLanguage
        Task { @MainActor in
            let engine = EngineFactory.makeEngine(profile: profile, keychain: .shared)
            let request = TranslationRequest(
                text: "Hello, world.",
                sourceLanguage: "en",
                targetLanguage: target
            )
            do {
                var output = ""
                for try await event in engine.translate(request) {
                    switch event {
                    case .delta(let chunk): output += chunk
                    case .replace(let whole): output = whole
                    case .reasoning, .usage, .model, .network, .done: break
                    }
                }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                test = trimmed.isEmpty ? .failure("引擎没有返回任何文本。") : .success(trimmed)
            } catch {
                test = .failure(error.localizedDescription)
            }
        }
    }
}
