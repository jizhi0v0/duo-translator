import SwiftUI

/// Reusable connections. One row per `Provider` (icon + name + type), click to
/// edit, add by kind. The detail form is connection-only — type, Base URL, API
/// key — so the same provider can back several translation cards and OCR, each
/// picking its own model elsewhere.
struct ProviderListView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: UUID?

    var body: some View {
        Group {
            if let id = selectedID,
               let index = settings.providers.firstIndex(where: { $0.id == id }) {
                detail(index: index)
            } else {
                listPane
            }
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            if settings.providers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($settings.providers) { $provider in
                        row($provider)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedID = provider.id }
                            .contextMenu {
                                Button("删除", role: .destructive) { remove(id: provider.id) }
                            }
                    }
                    .onMove { from, to in
                        settings.providers.move(fromOffsets: from, toOffset: to)
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
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("还没有供应商")
                .foregroundStyle(.secondary)
            Text("点左下角 + 添加一个供应商，翻译和 OCR 都能复用")
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
                    Label("供应商", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Text(settings.providers[index].name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(role: .destructive) {
                    let id = settings.providers[index].id
                    selectedID = nil
                    remove(id: id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("删除此供应商")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ProviderDetailView(settings: settings, provider: $settings.providers[index])
        }
    }

    private func row(_ provider: Binding<Provider>) -> some View {
        let p = provider.wrappedValue
        return HStack(spacing: 10) {
            EngineIcon(kind: p.kind, size: 18)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name)
                Text(p.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let issue = providerConfigIssue(p) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(issue)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Button(kind.label) { addProvider(kind: kind) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("添加供应商")

            Spacer()

            Text("连接可被多张翻译卡片与 OCR 复用 · 点按编辑 · 右键删除")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(6)
    }

    private func addProvider(kind: ProviderKind) {
        let provider = Provider.makeDefault(kind: kind)
        settings.providers.append(provider)
        selectedID = provider.id
    }

    private func remove(id: UUID) {
        guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
        let removed = settings.providers.remove(at: index)
        KeychainStore.shared.deleteSecret(for: removed.id)
    }
}

/// Editor for one provider's connection: name, Base URL (LLM), API key.
struct ProviderDetailView: View {
    @ObservedObject var settings: SettingsStore
    @Binding var provider: Provider
    @State private var apiKey = ""
    /// The value loaded from the keychain in `onAppear`, so `onChange` tells a
    /// real edit from the programmatic load and doesn't rewrite the same secret
    /// (churning the iCloud keychain) every time the pane opens.
    @State private var loadedKey = ""

    private var referencingCards: [TranslationConfig] {
        settings.translationConfigs.filter { $0.providerID == provider.id }
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $provider.name)
                LabeledContent("类型", value: provider.kind.label)
            }

            if provider.kind == .openAICompat || provider.kind == .anthropic {
                Section("API") {
                    TextField("Base URL", text: $provider.baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                }
            }

            if provider.kind.needsAPIKey {
                Section("API Key（存储在钥匙串）") {
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) {
                            guard apiKey != loadedKey else { return }
                            KeychainStore.shared.setSecret(apiKey, for: provider.id)
                            loadedKey = apiKey
                        }
                }
            }

            if let issue = providerConfigIssue(provider) {
                Section("状态") {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section("用途") {
                if referencingCards.isEmpty {
                    Text(provider.kind.isLLM
                         ? "在「引擎」页用它添加翻译卡片，或在「OCR」页选它做识别。"
                         : "在「引擎」页用它添加翻译卡片。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("被 \(referencingCards.count) 张翻译卡片使用：\(referencingCards.map(\.name).joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let existing = KeychainStore.shared.secret(for: provider.id) ?? ""
            loadedKey = existing
            apiKey = existing
        }
    }
}
