# DuoTranslator

macOS 菜单栏翻译器，目标是取代 Bob：划词翻译、输入翻译、截图 OCR 翻译，多引擎流式输出，长文滚动不掉帧，配置走 iCloud 同步。

## 功能

| 触发 | 默认快捷键 | 行为 |
|---|---|---|
| 划词翻译 | ⌥D | 读取任意 app 中选中的文本并翻译（Accessibility 优先，剪贴板 ⌘C 兜底） |
| 输入翻译 | ⌥A | 唤起浮窗，粘贴/输入后回车翻译（Shift+回车换行） |
| 截图翻译 | ⌥S | 系统框选截图 → Vision OCR → 自动翻译 |
| 截图取字 | ⌥⇧S | 截图 OCR 后进输入框，可编辑再翻译 |

引擎（可多开并列结果，标签切换）：

- **OpenAI 兼容**：自定义 Base URL / 模型，支持 OpenAI、OpenRouter、ollama、LM Studio 等，流式输出
- **Anthropic**：Messages API，流式输出
- **DeepL**：官方 API，free（`:fx` key）/ pro 自动分流
- **Apple 本地翻译**：Translation framework，免费离线

## 构建

依赖：Xcode 16+（macOS 15 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate
xcodebuild -project DuoTranslator.xcodeproj -scheme DuoTranslator -configuration Debug build
```

Debug 构建用真实 Apple Development 证书手动签名（见 `Configs/Debug.xcconfig`）——**不要改成 ad-hoc**，否则每次重编译签名变化，辅助功能/录屏授权会反复失效。

## 权限

- **辅助功能**（划词翻译）：首次使用 ⌥D 时弹系统提示；授权后如快捷键取词仍无反应，重启 app。
- **屏幕录制**（OCR）：首次使用 ⌥S/⌥⇧S 时申请；**授权后必须重启 app 才生效**。macOS 15+ 会周期性重新确认录屏类 app，属系统行为。

## iCloud 同步

普通配置（语言、引擎、OCR、快捷键）走 `NSUbiquitousKeyValueStore`（带时间戳 last-writer-wins 合并）；API Key 走 iCloud 钥匙串（`kSecAttrSynchronizable`）。构建未携带相应 entitlement 时自动降级为纯本地，设置 → 同步页可查看状态。

启用步骤：

1. 在 [developer.apple.com](https://developer.apple.com/account) 创建 App ID `dev.bobby.DuoTranslator`，勾选 **iCloud** capability。
2. 创建两个 provisioning profile 并双击安装：
   - **Development**（绑定开发机 + Apple Development 证书）→ 日常开发
   - **Developer ID**（Profiles → macOS → Developer ID）→ 发布
3. 取消 `Configs/DuoTranslator.entitlements` 中两个被注释的 entitlement。
4. 在 `Configs/Debug.xcconfig` / `Release.xcconfig` 填入对应 `PROVISIONING_PROFILE_SPECIFIER`。
5. 重新构建。KVS 传播是分钟级，双机测试时别追假 bug。

## 发布

```bash
# 一次性：保存公证凭据
xcrun notarytool store-credentials duo-notary --apple-id <email> --team-id RS59HDH7Y3

Scripts/release.sh   # build → Developer ID 签名 → 公证 → staple → DMG
```

## 性能设计（反 Bob 掉帧）

结果视图是 TextKit 2 的 `NSTextView`（`Sources/UI/Panel/StreamingTextView.swift`），三条铁律：

1. 流式输出只 append（`textStorage.append`），永不整体重设文档；
2. 33ms 合并 flush（`StreamingTextModel`），属性只设一次 `typingAttributes`；
3. 绝不触碰 `NSTextView.layoutManager`——那会静默降级 TextKit 1，失去视口增量布局。

跟随滚动只在用户位于底部时生效，上滚即停。

## 工程结构

`project.yml` 是唯一工程定义（`.xcodeproj` 不入库），加/删文件后执行 `xcodegen generate`。模块划分见 `plans/ocr-icloud-vast-boole.md`。
