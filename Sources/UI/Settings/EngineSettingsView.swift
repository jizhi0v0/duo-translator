import SwiftUI

struct EngineSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            profileList
                .frame(minWidth: 180, maxWidth: 220)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedID == nil {
                selectedID = settings.engineProfiles.first?.id
            }
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(settings.engineProfiles) { profile in
                    HStack {
                        Circle()
                            .fill(profile.enabled ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(profile.name)
                        Spacer()
                        Text(profile.kind.label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 4) {
                Menu {
                    ForEach(availableKinds, id: \.self) { kind in
                        Button(kind.label) { addProfile(kind: kind) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedID == nil)
                Spacer()
            }
            .padding(6)
        }
    }

    /// M1 only ships the OpenAI-compatible engine; the rest arrive in M4.
    private var availableKinds: [EngineKind] { [.openAICompat] }

    @ViewBuilder
    private var detail: some View {
        if let index = settings.engineProfiles.firstIndex(where: { $0.id == selectedID }) {
            EngineProfileDetailView(
                profile: $settings.engineProfiles[index]
            )
            .id(settings.engineProfiles[index].id)
        } else {
            Text("选择或添加一个引擎")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addProfile(kind: EngineKind) {
        let profile = EngineProfile.makeDefault(kind: kind)
        settings.engineProfiles.append(profile)
        selectedID = profile.id
    }

    private func removeSelected() {
        guard let selectedID,
              let index = settings.engineProfiles.firstIndex(where: { $0.id == selectedID }) else { return }
        let removed = settings.engineProfiles.remove(at: index)
        KeychainStore.shared.deleteSecret(for: removed.id)
        self.selectedID = settings.engineProfiles.first?.id
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
