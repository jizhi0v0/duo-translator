# 链接翻译(Link Translation)——单 link,内置 agent-browser 抓正文 → 页面模式双语阅读

## Context

需求:新增「链接翻译」——用户给一个网页 URL,app 抓取网页**正文**后翻译,先只支持单 link。

两处已定方向(用户确认):

1. **正文抽取用原生 WKWebView + Mozilla Readability.js**(不是 agent-browser)。
   - **决策变更**:原定用 [vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser),但**实测**其 `read <url>` 并非轻量 HTTP 抓取 —— 它**必启动无头 Chrome**(spawn `--headless=new` 整棵 Chrome 进程树 + 自带 user-data-dir)并**留常驻 daemon**,依赖机器有 Chrome 或下 ~150MB Chrome for Testing,无"纯 HTTP 不开浏览器"模式。代价远高于当初拍板时的认知。
   - 既然要一个"能跑 JS 再抽正文"的浏览器引擎,**app 里本来就有 `WKWebView`** —— 内置、无外部依赖、无后台进程、不需 Chrome。→ 用隐藏 `WKWebView` 加载 URL,注入 **Readability.js**(`Sources/Resources/Readability.js`,Apache-2.0,已下 91KB)`new Readability(document.cloneNode(true)).parse()` 抽 `{title, content(HTML)}`,在页内把 content 的块级元素(p/h1-6/li/blockquote/pre)按 `\n` 拼成段落文本回传。
2. **入口"类似 OCR":当前剪贴板是文本且是 URL 时触发**。→ 独立菜单项 + 快捷键,读剪贴板,是 http(s) URL 才走链接流程(镜像 OCR 独立入口 + `ClipboardImage.read()` 的剪贴板判定)。

### 现状架构(已逐文件核实,可复用接缝)

- **翻译入口是纯字符串**:所有输入源最终写入 `PanelViewModel.inputText`,`run.start(text:)`([TranslationRunController.swift:75](../Sources/Session/TranslationRunController.swift#L75))吃单 `String`,段落结构靠 `\n` 承载。
- **异步输入源模板 = OCR**:`OCRSession`(ObservableObject + `Phase` 状态机 + `action` 补救按钮 + 注入闭包)→ `PanelController.showOCR`([:443](../Sources/UI/Panel/PanelController.swift#L443),先呈现面板再异步跑)→ `AppCoordinator.recognize`([:138](../Sources/App/AppCoordinator.swift#L138),`await` 后带 `panel.viewModel.ocr === session` 陈旧守卫,成功写 `inputText` 再 `translate()`)。**链接流程结构完全同构。**
- **正文输出 = 页面模式**:`PageModeView` / `PageModeLayout.textBlocks`([PageModeView.swift:217](../Sources/UI/Panel/PageModeView.swift#L217))按 `\n` 段落逐段配对双语对照 —— 抓来的正文天然适配。`presentPanel()` 每次强制 `viewModel.pageMode = false`([PanelController.swift:473](../Sources/UI/Panel/PanelController.swift#L473)),链接流程需放行 / 抓取成功后置真。
- **入口双份接线**:菜单 `StatusItemController.buildMenu`([:25](../Sources/App/StatusItemController.swift#L25))+ `@objc` 转发([:45](../Sources/App/StatusItemController.swift#L45));快捷键 `HotkeyManager`([:3,:13](../Sources/App/HotkeyManager.swift#L3))。
- **偏好** `SettingsStore`:`@Published var x { didSet { defaults.set(...) } }` + `Keys` 常量套路([:30](../Sources/Storage/SettingsStore.swift#L30))。
- **工程生成**:`.xcodeproj` 由 xcodegen 从 `project.yml`([project.yml](../project.yml))生成,`sources: - Sources` 整目录纳入 → 新增文件放 `Sources/` 下后 `xcodegen generate` 一次。app 未 sandbox(entitlements 为空),exec 内置 helper 无需沙盒例外。

## 关键设计决策 / 已知取舍

1. **WKWebView 抽正文**:隐藏 `WKWebView`(离屏)加载 URL,`navigationDelegate.didFinish` 后短暂 settle(~500ms,给 SPA 水合)再 `evaluateJavaScript` 注入 Readability.js + 抽取片段,拿回 `{title, text}`。单次抓取(镜像 OCR 一次一个),`CheckedContinuation` + 超时竞速(超时 `stopLoading` 抛错),单次 resume 守卫。WKWebView 须主线程,整条 coordinator 流已 `@MainActor`,契合。
2. **Readability.js 打包**:`Sources/Resources/Readability.js`(Apache-2.0)作 app 资源;`module.exports` 有 `typeof module` 守卫,页内 eval 后 `Readability` 为全局函数。`parse()` 返回 `content`(清洗后 HTML)→ 页内遍历块级元素取 `textContent` 拼 `\n` 段落;`parse()` 为 null 时回退 `document.body.innerText`。
3. **JS 渲染兜底能力**:WKWebView 能跑 JS,SPA 基本能抽到;仍抽得薄的极端页留作后续(可加重试/更长 settle)。http 页受 ATS 默认拦截(只接受 https 更稳),本期只放 https/http、http 失败给错误即可。
4. **段落规整**:JS 已回传 `\n` 分隔段落 + 标题;Swift 侧加可单测的 `ArticleText.normalize(_:)`(去首尾空白、折叠 3+ 连续空行)兜一层。

## 改动

### 资源
- `Sources/Resources/Readability.js`(已下,Apache-2.0)。确认 `xcodegen generate` 后进 app bundle(未知扩展名默认入 resources build phase;若没进则在 `project.yml` 显式加 resources)。无二进制、无签名步骤、无 `.gitignore` 改动。

### 新增源码(`Sources/Link/`、`Sources/Capture/`)
- **`Sources/Link/ArticleFetcher.swift`** —— `@MainActor final class ArticleFetcher: NSObject, WKNavigationDelegate`;`struct Article { title; text }`;`func fetch(url:timeout:) async throws -> Article`(每次抓取新建 `WKWebView`,retain 到完成;didFinish→settle→evaluateJS 抽取;didFail/超时抛错);`enum ArticleFetchError: LocalizedError { case load(String), empty, timeout }` 中文文案。Readability.js 从 bundle 读一次缓存。
- **`Sources/Link/ArticleText.swift`** —— `static func normalize(_:) -> String`,纯字符串处理。
- **`Sources/Link/LinkSession.swift`** —— 镜像 `OCRSession`:`@MainActor final class LinkSession: ObservableObject`,持 `url: URL`、`@Published title/phase(.fetching/.done/.empty/.failed)/text/action`、注入闭包 `reFetch`。
- **`Sources/Capture/ClipboardURL.swift`** —— 镜像 `ClipboardImage`:`static func read() -> URL?`,读 `NSPasteboard.general` 的 `.string`,trim 后校验 http/https scheme 且 host 非空。
- **`Sources/UI/Panel/LinkAttachmentBar.swift`** —— 镜像 `OCRAttachmentBar`:输入框顶部"链接 chip"(link 图标 + 标题 + host + `.fetching`/`.failed` 状态与补救),`onRemove` 清 `viewModel.link`。

### 修改源码
- **`PanelViewModel.swift`** —— 加 `@Published var link: LinkSession?`、`@Published var linkFetching = false`(镜像 `ocr`/`ocrRecognizing`,:38/:44)。
- **`PanelController.swift`** —— 加 `showLink(url:) -> LinkSession`(镜像 `showOCR`);`presentPanel()` 的 `pageMode = false`([:473](../Sources/UI/Panel/PanelController.swift#L473))在 link 流程下放行(或抓取成功后置真);`showInput`([:417](../Sources/UI/Panel/PanelController.swift#L417))/`close`([:499](../Sources/UI/Panel/PanelController.swift#L499)) 随手清 `link`/`linkFetching`。
- **`AppCoordinator.swift`** —— `translateLink()`:`ClipboardURL.read()` → 无则 `showNotice("剪贴板不是有效链接")`,有则 `beginLink(url:)`;`beginLink`/`fetch(into:)` 镜像 `beginOCR`/`recognize`:先 `showLink` 显"抓取中",`Task` 里 `ArticleFetcher.fetch` → `ArticleText.normalize`,带 `panel.viewModel.link === session` 守卫,成功写 `title`/`inputText`、置 `.done`、`pageMode = true`、`translate()`;失败置 `.failed` + `action`(错误留 session,不 `showNotice`);`reFetch` 重跑。持有一个 `ArticleFetcher`(`lazy`)。
- **`StatusItemController.swift`** —— 加 `makeItem("链接翻译", #selector(translateLink), keyEquivalent: "")` + `@objc` 转发(放 OCR 组附近)。
- **`HotkeyManager.swift`** —— 加 `static let translateLink = Self("translateLink", default: .init(.l, modifiers: [.option]))` + `onKeyUp` 绑定。
- **`InputSectionView.swift`** —— OCR 附件条同处([:56](../Sources/UI/Panel/InputSectionView.swift#L56))并列:`if let link = viewModel.link { LinkAttachmentBar(...) }`。

### 测试(接 `DuoTranslatorTests`,`xcodegen generate`)
- `Tests/ArticleTextTests.swift`:`normalize` 去首尾空白、折叠连续空行、保留段落。
- `Tests/ClipboardURLTests.swift`(URL 校验拆纯函数):http/https 通过,纯文本/裸词/非法 scheme 拒绝。

## 不做 / 留后续
更强的 SPA 抽取(重试/更长 settle)、面板内粘贴 URL 直识别、批量多 link、http/ATS 例外。

## 验证
1. 构建:`xcodegen generate` → build;确认 `Readability.js` 进了 `.app/Contents/Resources/`。
2. 单测:`xcodebuild ... test -only-testing:DuoTranslatorTests/ArticleTextTests`(及 ClipboardURL)。
3. Release 装机(memory:Release 安装固定流程):复制文章 URL → 菜单「链接翻译」/⌥L → 面板出"抓取中"chip → 正文落 input、自动进页面模式双语对照、翻译流式出。
4. 反例:剪贴板放普通文本 → "剪贴板不是有效链接";无网络/坏 URL → chip 失败 + 重试。
5. 回归:划词/截图/输入翻译四条老路径不受影响(共用 `presentPanel`,注意 pageMode 复位改动别回归 OCR 紧凑卡片默认)。
