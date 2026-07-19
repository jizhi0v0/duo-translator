import SwiftUI

/// Bob-style engine service list: one row per profile (icon + name + enable
/// toggle), click to edit, drag to reorder. The list order is the array order
/// in `SettingsStore.engineProfiles`, which also determines the order of the
/// result cards in the translation panel.
struct EngineListView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach($settings.engineProfiles) { $profile in
                        NavigationLink(value: profile.id) {
                            row($profile)
                        }
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

                Divider()
                bottomBar
            }
            .navigationDestination(for: UUID.self) { id in
                if let index = settings.engineProfiles.firstIndex(where: { $0.id == id }) {
                    EngineProfileDetailView(profile: $settings.engineProfiles[index])
                        .navigationTitle(settings.engineProfiles[index].name)
                } else {
                    Text("该引擎已被删除")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ profile: Binding<EngineProfile>) -> some View {
        HStack(spacing: 10) {
            EngineIcon(kind: profile.wrappedValue.kind, size: 18)
                .foregroundStyle(profile.wrappedValue.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.wrappedValue.name)
                Text(profile.wrappedValue.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: profile.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
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

            Spacer()

            Text("拖动排序，顺序即翻译窗口卡片顺序；右键删除")
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

            if profile.kind.needsAPIKey {
                Section("API Key（存储在钥匙串）") {
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) {
                            KeychainStore.shared.setSecret(apiKey, for: profile.id)
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
        }
        .formStyle(.grouped)
        .onAppear {
            apiKey = KeychainStore.shared.secret(for: profile.id) ?? ""
        }
    }
}
