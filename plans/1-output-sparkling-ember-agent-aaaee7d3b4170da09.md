# 面板高度 / 拖拽 bug 调查报告

对象仓库: duo-translator (macOS 划词翻译, SwiftUI + AppKit 面板)。
关键文件: Sources/UI/Panel/PanelController.swift (含 `PanelLayout`、`WindowDragState`)、
PanelRootView.swift、ResultListView.swift、ResultCardView.swift、PanelViewModel.swift。

---

## 结论速览 (三个 bug 的根因)

三个现象共同来自同一个设计: **`refit()` 每次都把"结果区预算 / 窗口高度"重新算成窗口
垂直位置的函数** —— 具体是 `roomBelowTop = panel.frame.maxY - visible.minY`
(顶边到屏幕底的距离)。窗口越靠下 → `roomBelowTop` 越小 → `allowed` 越小 →
`resultAreaBudget` 越小 → 卡片 body cap 越小 → output 变矮 + 出现滚动条。
往上拖则相反 → output 变高。这是最近 commit 961179e 引入的行为。

- Bug1 (触底变矮): PanelController.swift:649-668, 686-692, 1018-1023 + ResultListView.swift:71-95
- Bug2 (触顶触发高度行为): 同一条链, `roomBelowTop` 触顶时被顶到 `ceiling` (PanelController.swift:637-657)
- Bug3 (流式结束后拖动仍变化/闪烁): refit 无条件在每次 drag settle / windowDidMove 重算 (PanelController.swift:747-778, 900-909)

---

## 1. 面板高度如何计算与应用

`PanelLayout` (纯函数, PanelController.swift:1004-1118) 提供公式, `refit()` 负责调用并 setFrame。

- `refit(display:)` — **唯一** setFrame 的地方 (窗口尺寸权威): PanelController.swift:627-713。
  - guard: 仅 `windowDragPhase == .idle` 才动几何 (628-633)。
  - `visible = screen.visibleFrame`; `ceiling = max(minFittedHeight, visible.height - screenPadding*2)` (636-640) —— 全屏可用高。
  - `resultFloor = runs.isEmpty || ocrRecognizing ? 0 : minVisibleResultStrip(=150)` (649-650, 常量 205)。
  - `allowed = PanelLayout.allowedFitHeight(roomBelowTop: panel.frame.maxY - visible.minY, screenCeiling: ceiling, minHeight: minFittedHeight(220), chrome: chromeHeightMeasured + fitBuffer(6), resultFloor)` (651-657)。
  - **发布预算**: `budget = max(0, allowed - chrome - fitBuffer)`; `viewModel.resultAreaBudget = budget` (665-668)。
  - 模式切换护栏: `canUseResultMeasurement(...)` 未就绪则 return, 保持当前高度 (674-678)。
  - `desired = PanelLayout.windowHeight(chrome, result: resultHeightMeasured, buffer, floor, ceiling: allowed)` (686-692)。
  - 抖动过滤: `abs(desired - panel.frame.height) > 4` 才继续 (693)。
  - **顶边钉住**: `topY = frame.maxY; frame.size.height = desired; frame.origin.y = topY - desired` (695-698)。
  - 之后再经 `WindowDragState.dragOrigin(...)` 二次钳制 origin (705-711), 然后 `panel.setFrame` (712)。

- `PanelLayout` 公式:
  - `allowedFitHeight = min(screenCeiling, max(roomBelowTop, max(minHeight, chrome+resultFloor)))` (1018-1023)。
  - `windowHeight = min(max(chrome+result+buffer, floor), ceiling)` (1037-1041)。
  - `scrollViewportHeight = min(max(0,content), max(0,budget))` (1008-1010)。
  - `perCardBodyMax = max(floor, (budget - n*cardChrome)/n)` (1053-1058)。
  - body 相关: `stableBodyHeight` / `growingBodyHeight` / `bodyHeight` / `clampDraggedBodyHeight` (1081-1117)。

- 谁触发 refit:
  - chrome 高度变化 onChromeHeightChange → refit (PanelController.swift:266-273; 报告点 PanelRootView.swift:114-117)。
  - 结果内容高度 onContentHeightChange → `acceptResultHeight` → refit (260-265, 354-368)。
  - 模式宽度 applyModeWidth → refit x2 (298-347)。
  - drag settle 尾帧 → refit (772)。
  - windowDidMove(.idle) → refit (908)。
  - resetPanelPosition → refit (619)。

- `acceptResultHeight` (350-368): 仅接受当前可见模式的测量, 存入 `resultHeightMeasured` + `cachedResultHeights[pageMode]`, 宽度一致时 refit。

- `resultHeightMeasured` / `chromeHeightMeasured` 定义: PanelController.swift:134-135; 常量
  `minFittedHeight=220` (192), `screenPadding` (194), `fitBuffer=6` (200),
  `minVisibleResultStrip=150` (205)。

---

## 2. 屏幕边界钳制 + "拖到底不自动扩展"改动

- **位置钳制** `WindowDragState` (PanelController.swift:920-998):
  - `windowOrigin` 按指针 delta 精确平移, 故意不钳制 (927-936)。
  - `constrainedOrigin` 把整窗限制进 visibleFrame (941-955)。
  - `dragOrigin` (963-997): 竖直方向 `minY=pointerScreen.minY`, `maxY=max(minY, pointerScreen.maxY - windowSize.height)`, `y=clamp(proposed.y, minY, maxY)` (970-972) —— 窗口底不越屏底、顶不越屏顶 (菜单栏)。横向可跨屏 (工具栏 band 落在的所有屏)。
  - 拖拽中 (mouseDragged, 60-93) 与 refit 尾部 (705-711) 都调 `dragOrigin`。

- **最近改动 (commit 961179e "Panel: draggable window position, remembered per screen")**:
  旧代码 `ceiling = max(minFittedHeight, min(visible.height-2*padding, roomBelowTop))`, 直接把
  `roomBelowTop` 当 ceiling。新代码拆成: `ceiling`=全屏, 再用
  `allowedFitHeight(roomBelowTop, ...)` 把窗口"能长到多高"限制在**顶边以下的空间**;
  旧的越底后被上推填满全屏的行为被移除, 改成"到屏底就停、body 内部滚动"。
  → 这正是"拖到底不再自动往下扩展"的实现, 也是新引入 `resultFloor/minVisibleResultStrip=150` 的地方。
  (diff: `git show 961179e -- Sources/UI/Panel/PanelController.swift`, refit hunk ~330-430。)

- **触底 (bug1) 发生什么**: 顶边被拖低 → `roomBelowTop` 变小 → `allowed` 变小 →
  `budget=allowed-chrome-buffer` 变小 (665) → `resultAreaBudget` 下降 → 结果区/卡片 body 变矮 +
  滚动条。同时 `desired`(686) 受 `allowed` 上限压制, 窗口本身也可能变矮。
  当顶边极低触发 need-driven floor (`max(220, chrome+150)`) 时, `desired>roomBelowTop`,
  origin.y 会被 dragOrigin 上抬 (970-972) —— 顶边被动上移。

- **触顶 (bug2)**: 顶边拖到 `visible.maxY` (dragOrigin 的 maxY 钳制 971) → `roomBelowTop` 达到全屏高 →
  `allowed=ceiling`(最大) → budget/desired 跳到接近满屏 → 触顶瞬间窗口可突然长高。

---

## 3. 拖拽逻辑 + per-screen 位置记忆

- **拖拽手柄** `WindowDragHandle` / `DragView` (PanelController.swift:42-111):
  - `mouseDown` (47-58): 双击→`onDragHandleDoubleClick` (重置位置); 否则记录起点 + `onDragBegan`。
  - `mouseDragged` (60-93): 算 proposed origin → `dragOrigin` 钳制 → 整数化 → `setFrameOrigin` + `onDragMoved`。
  - `mouseUp`/`endDrag` (95-104): `onDragEnded`。
  - 手柄挂在工具栏背后: PanelRootView.swift:87 `.background(WindowDragHandle())`; 窗口背景拖拽关闭 (isMovable=false, PanelController.swift:226-227), 保证拖滚动条是滚动而非移窗。
  - 注: 刻意不用 `NSWindow.performDrag(with:)` (设计注释 38-41), 避免 WindowServer 把窗口拉回屏内。

- **回调接线**: onDragBegan→`beginWindowDrag`, onDragMoved→`restoreScrollPositions`,
  onDragEnded→`finishWindowDrag`, 双击→`resetPanelPosition` (PanelController.swift:255-258)。

- **拖拽生命周期** (WindowDragPhase = idle/dragging/settling, 159-164):
  - `beginWindowDrag` (718-737): 冻结滚动位置, `viewModel.windowDragActive=true`, phase=.dragging, 起 60Hz 释放轮询。
  - `pollWindowDragRelease` (739-745): 鼠标仍按→restoreScroll; 否则 `finishWindowDrag`。
  - `finishWindowDrag` (747-778): phase=.settling → 两跳 async: 先解冻 (windowDragActive=false, layout),
    再 phase=.idle + **`refit()`** + `saveDraggedPanelPosition()` (772, 775)。generation 护栏防止旧手势的 settle 干扰新手势。
  - `windowWillMove` (890-894) / `windowDidMove` (900-910): NSWindow 层兜底; `.idle` 时 windowDidMove 也会 async `refit()` (908)。

- **per-screen 位置存取**:
  - `screenKey(for:)` (588-593): CGDirectDisplayID → `"display-<id>"`, 回退像素尺寸。
  - `placeOnActiveScreen` (554-584): 读 `SettingsStore.panelTopLeft(forScreen:)`; 有则 `constrainedOrigin` 钳回屏内后 setFrame; 无则默认顶部居中 (顶边=visible.maxY-padding)。
  - `saveDraggedPanelPosition` (597-605): 存 `(x, frame.maxY)` 即左上角。
  - `resetPanelPosition` (609-619): 双击清除记忆 → 回默认顶部居中 → refit。
  - 存储: SettingsStore.swift `panelTopLeftByScreen: [String:[Double]]` (key 27, prop 73-75)。

---

## 4. 流式期间 / 结束时的高度更新路径

- 每个卡片 body: `ResultCardView` (Sources/UI/Panel/ResultCardView.swift)
  - `StreamingTextView` 用 `heightCeiling: maxBodyHeight`, `suppressFollow: layoutFrozen`,
    `onContentHeightChange: { measuredBodyHeight = $0 }` (65-76)。
  - `bodyHeight = PanelLayout.bodyHeight(dragged, measured: measuredBodyHeight, floor, cap: maxBodyHeight)` (233-240)。
  - `displayedBodyHeight = layoutFrozen ? lastDisplayedBodyHeight : bodyHeight` (242-244) —— 拖拽时冻结显示高度。
  - `.onGeometryChange`: 非冻结时更新 `lastDisplayedBodyHeight` (78-80)。
  - `maxBodyHeight` 来自 ResultListView.perCardMaxBody (下)。

- 列表: `ResultListView` (Sources/UI/Panel/ResultListView.swift)
  - `onResultsHeightChange($0)` 整个结果区高度上报 → onContentHeightChange(false,·) → acceptResultHeight → refit (14-19, 59-61)。
  - `listViewportHeight = scrollViewportHeight(content: measuredCardStackHeight, budget: resultAreaBudget)` (71-77)。
  - `perCardMaxBody = perCardBodyMax(count, budget: resultAreaBudget - 上下 padding - 卡间距, cardChrome:90, floor:96)` (82-95)。

- 通知链 (流式中): StreamingTextView 测得内容高 → measuredBodyHeight → card body 变化 →
  ResultListView 高度变化 → onResultsHeightChange → acceptResultHeight → **refit** →
  更新 resultAreaBudget → 反过来改 perCardMaxBody/listViewportHeight。
  `resultAreaBudget` 定义与用途: PanelViewModel.swift:55-59; `windowDragActive` 60-63。

- 拖拽期间: `viewModel.windowDragActive=true` → 卡片 `layoutFrozen` → 显示高度锁 `lastDisplayedBodyHeight`;
  refit 被 phase guard 挡住 (633)。释放后 settle 一次性 catch-up refit (772)。

- 流式结束: run.state 由 .streaming→.done, `reusableResultHeight` 允许复用缓存高度 (371-...);
  但**任何后续 drag 仍会走 finishWindowDrag→refit / windowDidMove→refit**, 重新按位置算 budget/height。

---

## 5. 所有会导致"窗口/输出变矮"的路径 + 触顶移 origin 的代码

1. **主因**: `allowed` 受 `roomBelowTop = panel.frame.maxY - visible.minY` 上限压制
   (PanelController.swift:652 + allowedFitHeight 1018-1023)。窗口越靠下 allowed 越小 →
   `budget`(665) 与 `desired`(686-692) 都变小 → 窗口和输出区都变矮。

2. `resultAreaBudget` 下降的连锁: budget↓ → ResultListView.perCardMaxBody↓ (87-94) →
   ResultCardView.maxBodyHeight(cap)↓ → bodyHeight↓ (233-240) → 卡片 body 变矮 + StreamingTextView 内滚。
   同时 listViewportHeight = min(content, budget) ↓ (71-77) → 结果区外框变矮。

3. `windowHeight` 的 ceiling 传入的是 `allowed` 而非全屏 ceiling (692) —— 位置低时直接压低窗口高。

4. **触顶/触底移动 origin**: refit 尾部 `dragOrigin` 的竖直钳制
   `y = clamp(proposed.y, minY, maxY)`, `maxY = pointerScreen.maxY - windowSize.height` (970-972),
   当 need-driven floor 使 `desired > roomBelowTop` 时把顶边上抬; 触顶时 maxY 钳制把顶边定在 visible.maxY。
   drag 中的 mouseDragged 同样调用 dragOrigin (73-81)。

5. 次要 clamp: `scrollViewportHeight = min(content, budget)` (1008-1010);
   `perCardBodyMax` 的 `(budget - n*cardChrome)/n` (1053-1058)。

6. 闪烁来源 (bug3): finishWindowDrag 两跳 async + layoutSubtreeIfNeeded + refit (759-777);
   windowDidMove(.idle) 额外 async refit (908); 抖动阈值 4pt (693) 之上的每次重算都会 setFrame。

---

## 建议排查方向 (供后续修复, 非本次改动)

- 让 `resultAreaBudget` / 窗口高度在"结果已渲染 + 非增长"时**不随窗口 y 位置回缩**:
  区分"内容真的需要更多高度(向下增长)"与"仅仅是窗口被拖低" —— 后者不应缩小 budget。
- 触底: 允许保持既有窗口高度(或让底边跟随而非压 budget), 只有内容继续增长且已到屏底时才转内滚。
- 触顶: 顶边钳到 visible.maxY 后不要把 allowed 直接放大到 ceiling 造成跳高。
- bug3: 流式结束(所有 run settled)后, drag settle 的 refit 应为 no-op(仅记忆位置, 不重算高度/budget)。
