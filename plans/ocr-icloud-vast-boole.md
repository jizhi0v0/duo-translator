# DuoTranslator — macOS 翻译器实现计划

## Context

从零开发一个 macOS 菜单栏翻译 app（仓库 `/Users/bobby/Developer/github/duo-translator`，当前为空，未 git init），目标是取代 Bob.app——Bob 在长翻译结果滚动时掉帧，且作者已停止维护。macOS only，不做 iOS。用户有付费开发者账户。

已确认的需求决策：
- **三种触发流**：① 划词 + 快捷键 → 浮窗显示翻译；② 快捷键唤起输入窗口 → 粘贴/输入 → 翻译；③ OCR 两个快捷键：截图→OCR→自动翻译（一步）、截图→OCR→进输入框可编辑后再翻译（两步）。
- **引擎**：LLM API（OpenAI 兼容自定义 base URL/模型 + Anthropic，**流式输出**）、DeepL 官方 API、Apple Translation framework（本地免费）。
- **iCloud 同步**：普通配置走 `NSUbiquitousKeyValueStore`；API key 存 Keychain 且 `kSecAttrSynchronizable = true`（iCloud Keychain 同步）。
- **分发**：Developer ID 签名 + 公证，不上 App Store，**不开沙盒**（Accessibility 划词取词与沙盒不兼容；Developer ID + provisioning profile 下 iCloud KVS 无需沙盒）。
- **核心质量目标**：长文本流式翻译期间滚动不掉帧（Bob 的痛点）。

## 基础决策

| 项 | 选择 | 理由 |
|---|---|---|
| 工程管理 | **XcodeGen**（本机已装），提交 `project.yml`，gitignore `.xcodeproj` | diff 可读，避免 pbxproj 冲突；单 target 用 Tuist 过重 |
| 最低系统 | **macOS 15**（用户机器是最新系统，个人自用） | Translation framework / 新 Vision API 无需 `@available` 门控；如以后要支持旧机器，降到 14 只需给 Apple 引擎加门控 |
| App 形态 | `LSUIElement` 菜单栏 app，AppKit 驱动：`NSStatusItem` + `NSPanel`，SwiftUI 做 Settings 和面板内容（`NSHostingView`） | `MenuBarExtra` 对非激活浮窗控制力不足 |
| 三方依赖 | 仅 **sindresorhus/KeyboardShortcuts**（MIT, SPM）：全局快捷键 + 现成录制 UI | 其余全用系统框架：Vision、Translation、NaturalLanguage、Security、ApplicationServices |
| Debug 签名 | 从 M0 起就用真实 Apple Development 证书签 Debug | ad-hoc 每次重编译签名变 → Accessibility/录屏授权反复失效 |

## 文件布局

```
duo-translator/
├─ project.yml                       # XcodeGen：target、SPM 依赖、xcconfig、entitlements
├─ Configs/                          # Shared/Debug/Release.xcconfig、entitlements、Info.plist
├─ Sources/
│  ├─ App/          # DuoTranslatorApp、AppDelegate、StatusItemController、HotkeyManager
│  ├─ Capture/      # SelectedTextProvider、AXSelectionReader、PasteboardCopyFallback、PermissionCenter
│  ├─ OCR/          # ScreenshotCapturer（screencapture -i 包装）、TextRecognizer（Vision）
│  ├─ Engines/      # TranslationEngine 协议、SSEClient、OpenAICompat/Anthropic/DeepL/AppleTranslation
│  ├─ Language/     # LanguagePolicy（检测 + zh↔en 自动互换）
│  ├─ Session/      # TranslationCoordinator（多引擎 fan-out、取消）
│  ├─ UI/Panel/     # TranslatorPanel(NSPanel)、PanelController、PanelRootView、StreamingTextView
│  ├─ UI/Settings/  # SettingsView（General/Engines/Hotkeys/OCR/Sync 标签页）
│  ├─ Storage/      # SettingsStore（UserDefaults⇄iCloud KVS 镜像）、KeychainStore
│  └─ Support/      # os.Logger 等
├─ Tests/           # SSE 解析、LanguagePolicy、SettingsStore 合并、引擎请求构造
└─ Scripts/         # bootstrap.sh、release.sh（build→sign→notarize→staple→dmg）
```

## 关键设计

### 引擎抽象（流式优先）
```swift
enum TranslationEvent { case delta(String); case replace(String); case done(TranslationResult) }
protocol TranslationEngine: Identifiable, Sendable {
    var isAvailable: Bool { get }   // key 已配置、系统版本满足
    func translate(_ req: TranslationRequest) -> AsyncThrowingStream<TranslationEvent, Error>
}
```
- 非流式引擎（DeepL、Apple）发一次 `.replace` + `.done`，UI 层统一处理。
- `TranslationCoordinator` 把一次请求 fan-out 给 N 个启用引擎（各自子 Task），ESC/新请求/关窗取消全部（`onTermination` 里取消 URLSession task）。
- 共享 `SSEClient`：`URLSession.bytes` → `lines` → 解析 `data:` 帧；OpenAI 取 `choices[0].delta.content`，Anthropic 取 `content_block_delta.text_delta.text`；非 200 读完整 body 转成友好错误。
- OpenAI 兼容引擎从第一天就用 **多 profile 数组**（base URL + 模型 + 可编辑 system prompt 模板 `{{target}}/{{text}}`），方便同时配 OpenRouter/ollama 等。
- DeepL：key 以 `:fx` 结尾走 `api-free.deepl.com`；语言码映射表（`ZH`/`EN-US`）；解析 456 配额错误。
- **Apple Translation 的坑**：`TranslationSession` 不能命令式创建，只能由 SwiftUI `.translationTask` 提供。方案：面板窗口里挂一个 1×1 隐形 SwiftUI host view，`.translationTask` 把 session 交给 actor（continuation 队列），引擎入队请求后 invalidate config 触发；处理语言包下载状态。

### 划词取词（优先级顺序）
1. **AX 路径**：`AXUIElementCreateSystemWide` → focused element → `kAXSelectedText`；空则试 `kAXSelectedTextRange` + `kAXStringForRange`（WebKit）；Chromium/Electron 先对目标 app 设 `AXManualAccessibility = true` 等 ~100ms 重试一次。
2. **剪贴板兜底**：快照 `NSPasteboard`（全部类型 + changeCount）→ CGEvent 发 Cmd+C → 轮询 changeCount ≤300ms → 读文本 → 延迟 ~100ms 恢复快照。检测 `IsSecureEventInputEnabled()`，安全输入时给提示而不是静默失败。
- 权限：首次使用划词快捷键时才 `AXIsProcessTrustedWithOptions(prompt)`，Settings 里放"打开系统设置"深链。

### OCR
- 截图：`Process` 调 `/usr/sbin/screencapture -i -x <scratch.png>`（系统级框选 UI，ESC 取消 = 空文件；TCC 归因到本 app）。首次使用前 `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`；授权后需重启 app——写进引导 UI。
- 识别：Vision `VNRecognizeTextRequest`，`.accurate` + `usesLanguageCorrection` + `automaticallyDetectsLanguage`，`recognitionLanguages` 默认 `["zh-Hans","zh-Hant","en-US","ja"]` 可配置；行合并启发式（y 间距阈值；CJK 行直接拼接、拉丁行加空格）。
- 两个流共用管线：`capture → ocr → 自动翻译` vs `capture → ocr → 填入输入框`。

### 浮窗与流式渲染性能（反 Bob 掉帧的核心）
- `TranslatorPanel: NSPanel`：`.nonactivatingPanel`、`level = .floating`、`becomesKeyOnlyIfNeeded`、`canJoinAllSpaces + fullScreenAuxiliary`；出现在鼠标位置并 clamp 到屏幕内；ESC 关闭、可 pin（pin 时忽略外点关闭）；输入流用 `panel.makeKey()` 不激活 app，划词流不抢焦点。
- 结果区用 **`StreamingTextView`**（`NSViewRepresentable` 包 TextKit 2 的 `NSTextView(usingTextLayoutManager: true)`），面板 chrome（输入框/引擎切换/工具栏）用 SwiftUI。
- 流式渲染四条铁律：
  1. **只 append，永不整体重设文档**：`textStorage.replaceCharacters(in: endRange, with: chunk)`。
  2. **33ms 合并 flush**（`.done` 时立即 flush）；属性用 `typingAttributes` 设一次，流式期间不做 markdown 解析（完成后可选一次性渲染）。
  3. **绝不触碰 `.layoutManager`**（会静默降级 TextKit 1，失去视口增量布局）。
  4. **条件跟随滚动**：仅当用户在底部时 scrollToEnd；用户上滚即停止跟随，显示"回到最新"按钮。
- 面板高度随内容增长到上限（如屏幕 60%）后内部滚动；多引擎结果 v1 先用分段控件/tabs 切换，堆叠视图作为后续迭代。

### 快捷键
四个 `KeyboardShortcuts.Name`：划词翻译（默认 ⌥D）、输入窗口（⌥A）、OCR 一步翻译（⌥S）、OCR 进输入框（⌥⇧S）。Settings→Hotkeys 用 `KeyboardShortcuts.Recorder`。

### 配置与 iCloud 同步
- `SettingsStore: ObservableObject` 单一数据源，本地 UserDefaults 优先（M1–M4 无 iCloud 也完全可用）。
- `CloudSync` 镜像白名单 key 到 `NSUbiquitousKeyValueStore`；KVS 无元数据，每个 key 存 `{"v":…, "t":时间戳}` 信封做 last-writer-wins；监听 `didChangeExternallyNotification` 应用远端变更。快捷键（KeyboardShortcuts 的 UserDefaults key）也纳入同步。
- `KeychainStore`：`kSecClassGenericPassword` + `kSecAttrSynchronizable = true` + **`kSecUseDataProtectionKeychain = true`**（macOS 同步必需）+ `kSecAttrAccessibleAfterFirstUnlock`；`errSecMissingEntitlement`（无 profile 的开发期）时降级为不同步存储并在 Settings→Sync 显示状态。
- **Developer ID + iCloud 前置条件**（M5 时做）：portal 建带 iCloud capability 的 App ID；建 Development 和 Developer ID 两个 provisioning profile；entitlements 加 `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)$(CFBundleIdentifier)` 和 `keychain-access-groups`；release 构建嵌入 `embedded.provisionprofile` 手动签名。无 profile 时 KVS 会静默失效/崩溃——所以放 M5，不阻塞前期功能。

## 里程碑（每个结束都可运行）

- **M0 — 脚手架（半天）**：git init；`project.yml`（macOS 15、KeyboardShortcuts 依赖、xcconfig、entitlements 文件先注释掉 iCloud key）；`LSUIElement`；状态栏图标 + 空 Settings 窗口；Debug 用 Development 证书签名。
- **M1 — 输入窗口 + OpenAI 兼容流式引擎（2–4 天）**：⌥A 唤起浮窗；`TranslationEngine` 协议 + `SSEClient` + `OpenAICompatEngine`；`LanguagePolicy` zh↔en 自动互换；33ms 合并 flush + 条件跟随滚动**现在就做**（性能是 v1 特性不是后补）。验收：粘贴 5000 词文章流式翻译，期间滚动无掉帧（Instruments Animation Hitches 验证）。
- **M2 — 划词取词（2–3 天）**：AX + Electron poke + 剪贴板兜底；`PermissionCenter`；⌥D 全流程。测试矩阵：Safari、Chrome、VS Code、Slack/Electron、Preview PDF、Terminal、安全输入框。
- **M3 — OCR 两个流（2 天）**：截图包装 + 取消处理 + 录屏权限引导；Vision 识别 + 段落合并；⌥S 自动翻译、⌥⇧S 进输入框；Settings→OCR。
- **M4 — 多引擎（3–4 天）**：Anthropic、DeepL、Apple Translation（隐形 view 桥接 + 语言包下载 UX）；`EngineRegistry` 启用/排序；面板多结果展示；逐引擎错误态（key 错、配额、语言对不支持）。
- **M5 — iCloud 同步（2–3 天 + portal 配置）**：profile/entitlements 就位；`CloudSync` LWW 镜像；Keychain 切同步模式；Settings→Sync 状态页。双机测试（KVS 传播是分钟级，别追假 bug）。
- **M6 — 发布打磨（2–3 天）**：Hardened Runtime（AX/CGEvent 与之兼容，无需例外）；`release.sh`：archive → Developer ID 签名 → `notarytool submit --wait` → staple → DMG；首次运行权限引导；pin/复制按钮；图标；README。

## 主要风险

1. **Apple Translation 无命令式 API** — SwiftUI 桥接 + continuation 管线要预留时间（M4）。
2. **Electron/Java app AX 取词失败** — `AXManualAccessibility` poke 救大部分，剪贴板兜底救其余。
3. **Developer ID + iCloud 必须嵌 provisioning profile** — 否则 KVS 静默失效、Keychain 返回 `errSecMissingEntitlement`；已排到 M5 不阻塞。
4. **ad-hoc 签名导致 TCC 授权反复丢失** — M0 起用真证书签 Debug。
5. **TextKit 2 降级陷阱** — 碰 `.layoutManager` 即降级；append-only + 33ms 合并 + 条件跟随滚动三件套就是全部性能故事。
6. **非激活面板焦点舞蹈** — 输入流要 key、划词流不能抢焦点，M1/M2 交界处尽早测。
7. **录屏权限需重启生效**；macOS 15+ 会周期性重新提示录屏类 app，属预期行为。

## 验证方式

- 每个里程碑构建：`xcodegen && xcodebuild -project DuoTranslator.xcodeproj -scheme DuoTranslator build`，启动 app 实机走对应流程。
- M1 性能验收：长文流式翻译期间用 Instruments（Animation Hitches / Scroll Hitch Rate）确认无掉帧。
- M2 按测试矩阵逐 app 验证取词。
- 单元测试：SSE 解析器、DeepL 语言码映射、LanguagePolicy、Settings LWW 合并。
- M5 双机（或双用户账户）验证 KVS 与 Keychain 同步。
