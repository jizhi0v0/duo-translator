import SwiftUI

struct SyncSettingsView: View {
    private var kvsAvailable: Bool { CloudSync.hasKVSEntitlement }
    private var keychainSyncAvailable: Bool { CloudSync.hasKeychainGroupsEntitlement }

    var body: some View {
        Form {
            Section("状态") {
                statusRow(
                    "配置同步（iCloud KVS）",
                    available: kvsAvailable,
                    detail: kvsAvailable
                        ? "语言、引擎配置、OCR 与快捷键设置会在你的多台 Mac 间同步（传播可能需要几分钟）。"
                        : "当前构建未携带 iCloud entitlement，配置仅保存在本机。"
                )
                statusRow(
                    "API Key 同步（iCloud 钥匙串）",
                    available: keychainSyncAvailable,
                    detail: keychainSyncAvailable
                        ? "API Key 通过 iCloud 钥匙串同步（需在系统设置中开启 iCloud 钥匙串）。"
                        : "当前构建未携带钥匙串 entitlement，API Key 仅保存在本机钥匙串。"
                )
            }

            if !kvsAvailable || !keychainSyncAvailable {
                Section("启用步骤（需要 Apple 开发者账户）") {
                    Text("""
                    1. 在 developer.apple.com 创建 App ID `dev.bobby.DuoTranslator` 并勾选 iCloud capability。
                    2. 创建两个描述文件：Development（日常开发）与 Developer ID（发布），均绑定该 App ID。
                    3. 下载安装描述文件后，取消 Configs/DuoTranslator.entitlements 中被注释的两个 entitlement。
                    4. 在 Configs/*.xcconfig 里填入 PROVISIONING_PROFILE_SPECIFIER，重新构建。
                    详见 README 的 iCloud 同步一节。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusRow(_ title: String, available: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(available ? .green : .secondary)
                Text(title)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
