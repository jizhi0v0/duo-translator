# 拆分 Provider 与「翻译 / OCR」配置

## Context

现在 `EngineProfile`（[Sources/Storage/EngineProfile.swift](Sources/Storage/EngineProfile.swift)）把三件事塞在一个结构里：

1. **连接**：`kind` + `baseURL` + API Key（钥匙串按 profile.id 存）
2. **翻译选项**：`model` + `systemPromptTemplate` + 定价 + `enabled`（一条 = 一张结果卡片）
3. **OCR**：没有自己的配置，`OCRFactory` 直接按 UUID 复用某条翻译 `EngineProfile`，且必须 `kind.isLLM`、和翻译共用同一个 `model`

结果：想给 OCR 用一个视觉模型，就得把它配成一条启用的翻译引擎；同一个 provider 无法让翻译和 OCR 各用不同 model；也没有可复用的「连接」概念。`OCRSettingsView` 里那句「在引擎页配置 model」就是这层耦合的直接证据。

**目标**：把 **Provider（纯连接，可复用）** 抽出来，让 **翻译卡片** 和 **OCR** 各自引用一个 Provider 并独立选自己的 model。已与用户确认三点：
- Provider 只存连接（类型 + Base URL + Key），model 各功能各自选；
- DeepL、Apple 也统一进 Providers 列表；
- 「custom provider」= 任意 OpenAI 兼容 / Anthropic 端点（URL + key + 模型名），复用现有 kind，不做自定义 header/鉴权。

## 目标数据模型

三个概念拆开；`EngineProfile` **降级为运行时「已解析」的值类型（不再持久化）**，这样引擎、`VisionOCRRequest`、定价等消费方几乎不用改。

```
Provider            (持久化, 可复用)   —— 连接
  id, kind, name, baseURL              (Key 仍按 provider.id 存钥匙串)

TranslationConfig   (持久化)           —— 一张结果卡片（原 EngineProfile 的「翻译」部分）
  id, providerID, name, model,
  systemPromptTemplate, 定价×3, enabled

OCR 选择            (SettingsStore 键)  —— 单一激活项
  ocrProviderID: String?  (nil = Apple 内置 Vision；否则某 provider 的 uuid)
  ocrModel: String        (LLM provider 时用；Apple 忽略)
  仍保留 ocrVisionLevel / ocrLanguages / ocrMergesLines（Apple 路径）

EngineProfile       (改为运行时结构, 不持久化) —— provider+config 解析后的视图
  id(=config.id), kind, name, baseURL, model, systemPromptTemplate, 定价
  新增 init(provider:config:) 与 OCR 用的 init(provider:model:)
```

`EngineKind` → 重命名为 `ProviderKind`（机械改名；`isLLM` / `needsAPIKey` / `label` / 图标扩展保留）。能力由 kind 派生：`canTranslate`（全部）、`canOCR`（openAICompat / anthropic / apple）、`isLLM`（openAICompat / anthropic）。

## 改动分区

### 1. Storage
- 新增 [Sources/Storage/Provider.swift](Sources/Storage/Provider.swift)：`ProviderKind`（从 EngineProfile 迁出）+ `Provider` 结构。沿用 `EngineProfile` 里那套「每字段 `decodeIfPresent`」的容错 Codable 写法（见 EngineProfile.swift:53 的注释，避免加字段就整条解码失败）。`makeDefault(kind:)`、`normalize()` 一并迁来。
- 新增 [Sources/Storage/TranslationConfig.swift](Sources/Storage/TranslationConfig.swift)：原 `EngineProfile` 去掉 `kind`/`baseURL`、加 `providerID`，其余（model / prompt / 定价 / enabled）保留，同样的容错 Codable。
- 改 [Sources/Storage/EngineProfile.swift](Sources/Storage/EngineProfile.swift)：改成**非持久化**运行时结构，删掉自定义 `init(from:)`，加 `init(provider:config:)` 和 `init(provider:model:)`（OCR 用，prompt 用 VisionOCRRequest 的固定 prompt、定价置 0）。
- 改 [Sources/Storage/SettingsStore.swift](Sources/Storage/SettingsStore.swift)：
  - 新增 `@Published providers: [Provider]`、`translationConfigs: [TranslationConfig]`，及键 `providers` / `translationConfigs` / `ocrProviderID` / `ocrModel`。
  - `enabledProfiles`（翻译）→ 改为 `enabledConfigs`，并加 `resolvedEnabledEngines`（返回 `[EngineProfile]`，跳过 providerID 找不到的）。加 `provider(id:)`、`provider(for config:)` 辅助。
  - `resultBodyHeight(for:)` 等按 card id → 现在是 `TranslationConfig.id`，语义不变。
  - `reloadFromDefaults()` 同步读入新键。
  - **一次性迁移**（见下）。

### 2. 迁移（SettingsStore.init，一次性、幂等）
当新键 `providers` 缺失但旧键 `engineProfiles` 存在时：
- 每条旧 `EngineProfile P` → `Provider(id: P.id, kind, name, baseURL)` + `TranslationConfig(id: P.id, providerID: P.id, name, model, prompt, 定价, enabled)`。
  - **两者共用 P.id**（分属不同数组，UUID 不冲突）：钥匙串按 provider.id=P.id 仍有效；`resultBodyHeightByEngine` 按 card id=P.id 仍有效；卡片顺序不变。
  - 不做自动去重（去重要重排钥匙串，风险高），保持 1:1，用户可事后手动合并。
- OCR：旧 `ocrProvider == "apple"` → `ocrProviderID = nil`；旧 `ocrProvider == <uuid>` → `ocrProviderID = <uuid>`、`ocrModel = 该 profile 的 model`（保持「OCR 沿用该卡 model」的旧行为）。
- 迁移后可保留旧键不动（其他未升级设备/回滚仍可读）；判据「新键缺失」保证不重复迁移，且新键一旦经 iCloud 同步到别的设备，那台也会跳过迁移。
- **全新安装**（无任何旧数据）默认播种：一个 `openAICompat` Provider + 一条引用它的 `TranslationConfig`（对齐现状的单条默认引擎）；OCR 默认 Apple（`ocrProviderID = nil`）。可选再播种一个 Apple Provider，让列表里能看到本地翻译/OCR 项。

### 3. Factories
- [Sources/Engines/EngineFactory.swift](Sources/Engines/EngineFactory.swift)：`makeEngines` 用 `settings.enabledConfigs`，对每条 config 取其 provider、`EngineProfile(provider:config:)`、`keychain.secret(for: provider.id)`，再 `switch provider.kind` 建具体引擎。`makeEngine`（单卡重试）签名改为接收 `(config, provider)` 或已解析的 `EngineProfile`。**各引擎文件（OpenAICompatEngine / AnthropicEngine / DeepLEngine / AppleTranslationEngine）内部不动**——它们继续消费 `EngineProfile`。
- [Sources/OCR/OCRFactory.swift](Sources/OCR/OCRFactory.swift)：解析 `settings.ocrProviderID`——nil / 找不到 / 非 `canOCR` → `AppleVisionOCRProvider`（保留「任何异常都回退 Apple」的稳健性）；apple-kind → `AppleVisionOCRProvider`；openAICompat/anthropic → `LLMVisionOCRProvider(profile: EngineProfile(provider:model: settings.ocrModel), apiKey: keychain.secret(for: provider.id))`。
- [Sources/OCR/LLMVisionOCRProvider.swift](Sources/OCR/LLMVisionOCRProvider.swift) 与 [Sources/OCR/VisionOCRRequest.swift](Sources/OCR/VisionOCRRequest.swift)：继续接收 `EngineProfile`（现在由 OCR provider + `ocrModel` 解析而来），**无需改动**。

### 4. Settings UI
- **新增「供应商」Tab**（[Sources/UI/Settings/ProviderListView.swift](Sources/UI/Settings/ProviderListView.swift)）：仿现有 `EngineListView` 的列表/新增菜单/编辑/删除结构。详情表单只含**连接**：名称 / Base URL（LLM）/ API Key（钥匙串，复用现有 `SecureField` + `onChange` 落钥匙串逻辑）。删除 provider 时若仍被翻译卡片或 OCR 引用要给出提示/拦截。图标与 `logoAssetName`/`symbolName`/`label` 扩展从 EngineListView 迁到 `ProviderKind`。
- **改「引擎」Tab → 翻译卡片**（[Sources/UI/Settings/EngineListView.swift](Sources/UI/Settings/EngineListView.swift)）：每条 = 一张翻译卡片。详情表单把原来的 Base URL/API Key **换成一个 Provider 选择器**（Picker 选已有 provider，或「去添加供应商」）；保留 model / 系统提示词 / 定价 / 名称 / enabled。**连接测试留在这里**（有 provider+model+prompt，能跑真实一次翻译；`runTest` 逻辑基本不变，改为用解析出的 `EngineProfile`）。`engineConfigIssue` 改为基于 `(config, provider)` 校验（缺 provider / 缺 Base URL / 缺 model / 缺 key）。
- **OCR Tab**（[Sources/UI/Settings/OCRSettingsView.swift](Sources/UI/Settings/OCRSettingsView.swift)）：引擎 Picker 改为绑定 `ocrProviderID`（Apple 内置 + 所有 `canOCR` 的 provider）；选到 LLM provider 时多显示一个 **model 输入框**（绑定 `ocrModel`）。Apple 路径的精度/语言/排版不变。`normalizeSelection` 改为按 provider 存在性回退 Apple。
- [Sources/UI/Settings/SettingsWindowController.swift](Sources/UI/Settings/SettingsWindowController.swift)：在「引擎」前插入「供应商」Tab（symbol 如 `server.rack` / `cpu`）。

### 5. CloudSync
[Sources/Storage/CloudSync.swift](Sources/Storage/CloudSync.swift) `syncedKeys` 增加 `providers` / `translationConfigs` / `ocrProviderID` / `ocrModel`；旧的 `engineProfiles` / `ocrProvider` 暂留在列表中过渡（幂等迁移保证不冲突）。`ocrProviderID` 以 `String?`（uuidString）存，避免非 plist 类型。

### 6. Debug 路径
[Sources/App/AppCoordinator.swift:143-163](Sources/App/AppCoordinator.swift) `debugOCRTest`：从「第一个 openAICompat provider」+ `ocrModel`（或传入 model）解析出 `EngineProfile` 再建 `LLMVisionOCRProvider`。

### 7. 测试
更新引用旧 `EngineProfile(kind:...)` / `EngineKind` 的测试：`Tests/EngineProfileTests.swift`、`EngineParsingTests.swift`、`VisionOCRRequestTests.swift`、`RunMetricsTests.swift`、`PromptTemplateTests.swift`、`SmokeTests.swift`。改为构造 `Provider` + `TranslationConfig`（或直接构造运行时 `EngineProfile`）。新增：迁移测试（旧 `engineProfiles`+`ocrProvider` → providers/configs/ocrProviderID，且钥匙串 id 不变）、OCRFactory 解析/回退测试。工程文件由 XcodeGen 生成，新增 .swift 后需 `xcodegen generate`（见项目记忆）。

## Verification

1. `xcodegen generate` 后编译（Release，装到 /Applications，按项目记忆流程）。
2. **迁移**：用现有已配置好的构建启动一次 → 供应商 Tab 出现原有连接、翻译 Tab 卡片顺序与启用态不变、API Key 仍在（连接测试通过，无「未配置 API Key」）、OCR 选择保持原样。
3. **解耦复用**：加一个 OpenAI 兼容 Provider；翻译卡片选它 + model A；OCR 选同一 provider + model B → 两者用不同 model 各自工作。
4. **划词翻译**：多张卡片并行出译文（`TranslationRunController` 路径不变）。
5. **截图 OCR**：Apple 内置可用；切到 LLM provider + 视觉 model 能识别。
6. **自定义 provider**：填一个本地 Ollama/LM Studio 的 Base URL + 任意 model，连接测试通过。
7. `swift test` / Xcode 测试全绿，含新增迁移与 OCRFactory 测试。
