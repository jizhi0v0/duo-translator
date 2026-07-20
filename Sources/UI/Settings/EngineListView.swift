import SwiftUI

/// Bob-style engine service list: one row per profile (icon + name + enable
/// toggle), click to edit, drag to reorder. The list order is the array order
/// in `SettingsStore.engineProfiles`, which also determines the order of the
/// result cards in the translation panel.
struct EngineListView: View {
    @ObservedObject var settings: SettingsStore
    /// Which engine's detail is open, or nil for the list. We drive navigation
    /// by hand instead of `NavigationStack`: this view is hosted inside the
    /// settings window's tab controller, whose toolbar already owns the toolbar
    /// area, so a `NavigationStack` back button has nowhere to render and the
    /// user gets stuck on the detail page.
    @State private var selectedID: UUID?

    var body: some View {
        Group {
            if let id = selectedID,
               let index = settings.engineProfiles.firstIndex(where: { $0.id == id }) {
                detail(index: index)
            } else {
                listPane
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if settings.engineProfiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($settings.engineProfiles) { $profile in
                        row($profile)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = profile.id }
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    remove(id: profile.id)
                                }
                            }
                    }
                    .onMove { from, to in
                        settings.engineProfiles.move(fromOffsets: from, toOffset: to)
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
            Image(systemName: "engine.combustion")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("还没有翻译引擎")
                .foregroundStyle(.secondary)
            Text("点左下角 + 添加一个引擎")
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
                    Label("引擎", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(settings.engineProfiles[index].name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(role: .destructive) {
                    let id = settings.engineProfiles[index].id
                    selectedID = nil
                    remove(id: id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("删除此引擎")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            EngineProfileDetailView(profile: $settings.engineProfiles[index])
        }
    }

    private func row(_ profile: Binding<EngineProfile>) -> some View {
        let p = profile.wrappedValue
        return HStack(spacing: 10) {
            EngineIcon(kind: p.kind, size: 18)
                .foregroundStyle(p.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                Text(p.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            // Warn a new user that an enabled engine won't run as configured —
            // the default OpenAI profile ships without a key and would otherwise
            // fail silently at translate time.
            if p.enabled, let issue = engineConfigIssue(p) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(issue)
            }
            Spacer()
            Toggle("", isOn: profile.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            // Tap affordance now that the row isn't a NavigationLink.
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(EngineKind.allCases, id: \.self) { kind in
                    Button(kind.label) { addProfile(kind: kind) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("添加引擎")

            Spacer()

            Text("点按编辑 · 拖动排序（即卡片顺序）· 右键删除")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
    }

    private func addProfile(kind: EngineKind) {
        settings.engineProfiles.append(EngineProfile.makeDefault(kind: kind))
    }

    private func remove(id: UUID) {
        guard let index = settings.engineProfiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = settings.engineProfiles.remove(at: index)
        KeychainStore.shared.deleteSecret(for: removed.id)
    }
}

/// The first thing keeping this engine from running, or nil when it's ready.
/// Shared by the list warning badge and the detail-view status line so both
/// agree on what "configured" means.
@MainActor
func engineConfigIssue(_ profile: EngineProfile) -> String? {
    switch profile.kind {
    case .apple:
        return nil
    case .deepL:
        return KeychainStore.shared.hasSecret(for: profile.id) ? nil : "未配置 API Key"
    case .openAICompat, .anthropic:
        if profile.baseURL.isEmpty { return "缺少 Base URL" }
        if profile.model.isEmpty { return "缺少模型" }
        if !KeychainStore.shared.hasSecret(for: profile.id) { return "未配置 API Key" }
        return nil
    }
}

/// Numeric entry for a per-million-token price. Empty reads as 0, i.e. unknown.
private struct PriceField: View {
    @Binding var value: Double

    var body: some View {
        TextField("0", value: $value, format: .number.precision(.fractionLength(0...4)))
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
    }
}

extension EngineKind {
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

/// The engine's mark, tintable via `foregroundStyle` in both the result cards
/// and the settings list: a bundled brand logo where we have one, else the SF
/// Symbol fallback. Sizes itself to a square so the two render interchangeably.
struct EngineIcon: View {
    let kind: EngineKind
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

struct EngineProfileDetailView: View {
    @Binding var profile: EngineProfile
    @State private var apiKey = ""
    /// The key value loaded from the keychain in `onAppear`, so `onChange` can
    /// tell a genuine user edit from the programmatic load and not rewrite the
    /// same secret (churning iCloud keychain) every time the pane opens.
    @State private var loadedKey = ""
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $profile.name)
                Toggle("启用", isOn: $profile.enabled)
            }

            if profile.kind == .openAICompat || profile.kind == .anthropic {
                Section("API") {
                    TextField("Base URL", text: $profile.baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    TextField("模型", text: $profile.model)
                        .autocorrectionDisabled()
                }
            }

            if profile.kind.isLLM {
                // Prices are per model and change often, so they are entered
                // rather than baked in: a stale built-in table would report
                // confident, wrong costs. Left at 0, the readout simply omits
                // cost instead of inventing one.
                Section("价格（每百万 Token，留空则不显示成本）") {
                    LabeledContent("输入") {
                        PriceField(value: $profile.inputPricePerMTok)
                    }
                    LabeledContent("输出") {
                        PriceField(value: $profile.outputPricePerMTok)
                    }
                    LabeledContent("缓存输入") {
                        PriceField(value: $profile.cachedInputPricePerMTok)
                    }
                }
            }

            if profile.kind.needsAPIKey {
                Section("API Key（存储在钥匙串）") {
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) {
                            guard apiKey != loadedKey else { return }
                            KeychainStore.shared.setSecret(apiKey, for: profile.id)
                            loadedKey = apiKey
                        }
                }
            }

            if profile.kind == .openAICompat || profile.kind == .anthropic {
                Section("系统提示词（{{target}} 会替换为目标语言）") {
                    TextEditor(text: $profile.systemPromptTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 90)
                }
            }

            testSection
        }
        .formStyle(.grouped)
        .onAppear {
            let existing = KeychainStore.shared.secret(for: profile.id) ?? ""
            loadedKey = existing
            apiKey = existing
        }
    }

    /// Lets a new user confirm the engine actually works before relying on it,
    /// instead of discovering a bad key or URL only at translate time. Runs one
    /// real request through the same factory the app uses.
    @ViewBuilder private var testSection: some View {
        Section("连接测试") {
            if let issue = engineConfigIssue(profile) {
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
                .disabled(test == .running)

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
        test = .running
        let profile = self.profile
        let target = SettingsStore.shared.firstLanguage
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
