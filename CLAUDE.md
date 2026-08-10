# DuoTranslator — 给 agent 的工作须知

功能、构建依赖、权限、iCloud 同步启用步骤见 `README.md`,不在这里重复。

## 工程是生成的

`DuoTranslator.xcodeproj` 由 XcodeGen 从 `project.yml` 生成,且**已被 gitignore**——它是产物,不是源码。
`Sources` / `Tests` / `UITests` 三个 target 都按目录整体收录,所以**新建 `.swift` 之后跑一次 `xcodegen generate` 就够了**,不要去手改 `project.pbxproj`。
反过来:加了文件却没 generate,编译照样成功,只是你的代码根本没被编进去——遇到"改了没效果"先想这个。

## 验证

```bash
xcodegen generate
xcodebuild test -project DuoTranslator.xcodeproj -scheme DuoTranslator \
  -destination 'platform=macOS' DEVELOPMENT_TEAM=RS59HDH7Y3
```

只跑单测加 `-only-testing:DuoTranslatorTests`。UI 测试要求控制进程(Terminal/Xcode)在"辅助功能"里已授权。

**用户日常用的是 Release 装到 `/Applications` 的那份,不是 Xcode 的 Debug。** 所以:

- 装新版必须 `pkill -x DuoTranslator` 并确认 `pgrep -x` 归零,再 `open`。
  **`cp` 覆盖 + `open` 不等于跑上了新版本**——`open` 遇到已运行进程只是调前台,跑的还是旧二进制。
  说"修好了,你试试"之前先确认这一步做了,否则用户测的是旧代码。
- `/Applications` 是**共享资源**。并行会话或隔离 worktree 里的后台任务按同样流程重装,会把本会话未提交的修复顶掉,症状是"行为莫名回退、新加的日志钩子没反应"。
  核对办法:`ls -la /Applications/DuoTranslator.app/Contents/MacOS/DuoTranslator` 看 mtime 是不是自己那次安装。
  给后台任务写 prompt 时明确"不要重装 /Applications"。
- 装完**不要**默认 `tccutil reset`。只有签名身份变了(adhoc↔Developer ID、换证书/team/bundle id)才需要。

面板是 LSUIElement 的 nonactivating NSPanel,computer-use 点不到。要看视觉效果:用 `CGWindowListCopyWindowInfo` 拿窗口号,再 `screencapture -x -l<windowNumber>` 直接截窗口。

## 已经否掉的方案,不要再提

- **OCR 面板 UI**:最终形态是"图片作 input 附件"。塞进结果卡片 / 双模式 / 双窗口 / 左侧图栏——四种都评估过并否掉了。
- **快捷键录制**:不用 KeyboardShortcuts 自带的 Recorder(macOS 26 上点击会掉进文本模式),用自写的 `ShortcutRecorderView`。
- **链接翻译正文抓取**:不回 WKWebView + Readability(维护负担),走内置 agent-browser CLI。

面板布局有两条不变量,改之前先确认没违反:**流式输出不驱动布局**、**位置只涨不缩(棘轮)**。

## Git

- **用户常同时开多个会话改这个仓库,而且不常 commit**,同一批文件里会混着几个会话的未提交改动,甚至同一文件内逐行穿插。
- 被要求"回退某次改动"时,第一步永远是 `git status` + `git diff --stat`,再对每个文件 `git diff HEAD -- <file>` 确认改动是不是纯粹一个来源。
  **不要假设 `git checkout HEAD -- <file>` 安全。** 混合文件的正确做法是"整体 revert 到 HEAD,再重放要保留的那部分 edit",不是在混合 diff 里数行数。
- 解冲突就在冲突块里改,不要把内容追加到文件末尾。
