# 面板拖拽后高度稳定化:禁止"位置驱动的缩小" + 卡片 body 防回流棘轮

## Context

最近的改动(commit 961179e)让流式中拖到屏幕底部时面板不再自动向下扩展、output 内滚——这个保留。遗留问题:

1. **触底 output 变矮**:窗口拖到屏底后,output 区域会被压矮(不该发生);
2. **触顶跳变**:窗口拖到屏顶会触发高度突变;
3. **流式结束后拖动仍闪烁**:每次拖完 settle 都按新位置重算高度,期望结束后完全稳定。

### 根因(两层,已逐行核实)

- **位置进入了高度公式**:`refit()`([PanelController.swift:651](../Sources/UI/Panel/PanelController.swift#L651)-657)用 `roomBelowTop = panel.frame.maxY - visible.minY` 算 `allowed` → `resultAreaBudget`。窗口越低预算越小;触顶时 roomBelowTop=全屏,预算突然放大。
- **真正压矮 output 的主机制是均分再分配**:拖拽钳制保证窗口不出屏,所以正常拖拽中 `roomBelowTop ≥ 窗口高度` 恒成立——触底时预算恰好收敛到**等于**当前内容高度,而 `perCardBodyMax`(PanelLayout:1053-1058)把预算**均分**给各卡。双引擎两卡不等高(常态)时,高卡被裁向平均值 → stack 变矮 → `acceptResultHeight` 上报变矮 → `desired` 变矮 → 窗口缩 → 预算再缩,**向下迭代**直到高卡贴 floor。单卡/等高卡恰好是不动点,所以现象时有时无。触底↔拖上往返各裁/涨一轮 = 闪烁(问题 3);被裁矮的内容拖到顶一次性回涨 = "跳变"(问题 2)。

### 目标行为(设计不变量)

**位置移动永远不缩小任何已渲染的高度;高度只因内容变化(变短/新 run/模式切换)或用户显式手势(拖分隔线、双击 reset)而缩。** 向上生长照常:流式向下长到屏底为止,拖上后被裁剪内容可回涨(用户已接受)。触顶不再需要特判——修掉位置驱动缩小后它只是"拖上"的端点。

## 改动

### Step 1(主修):卡片 body 防回流棘轮 — PanelLayout + ResultCardView

`Sources/UI/Panel/PanelController.swift`(PanelLayout enum,~1104):

```swift
/// Cap that can stop future growth but never claw back rendered content.
static func effectiveBodyCap(cap: CGFloat, displayed: CGFloat?, measured: CGFloat?) -> CGFloat {
    Swift.max(cap, Swift.min(displayed ?? 0, measured ?? 0))
}

static func bodyHeight(
    dragged: CGFloat?, measured: CGFloat?, displayed: CGFloat?,
    floor: CGFloat, cap: CGFloat
) -> CGFloat {
    let effective = effectiveBodyCap(cap: cap, displayed: displayed, measured: measured)
    let ceiling = Swift.min(dragged ?? effective, effective)
    return growingBodyHeight(measured: measured, floor: floor, cap: ceiling)
}
```

`min(displayed, measured)` 语义:measured(内容自然高)变短 → 棘轮自动松开,正常收缩;新卡 measured=nil → 棘轮无效,走正常 share。

`Sources/UI/Panel/ResultCardView.swift`:
- `bodyHeight`(233-240)传 `displayed: lastDisplayedBodyHeight`(该 @State 已存在,78-80 由 onGeometryChange 维护,无需新状态);
- `resizeDivider` 的 `clampDraggedBodyHeight`(273-277)cap 换 `effectiveBodyCap(...)`——否则棘轮状态下(body > share cap)一碰分隔线卡片瞬间跳缩。

### Step 2(加固):`allowedFitHeight` 加 `currentHeight` — 堵跨屏/Dock 路径

主路径上 `roomBelowTop ≥ 当前高度` 恒成立,但**跨屏 straddle**(refit 用 `panel.screen` 最大重叠屏,拖拽钳制用指针屏,两屏 minY 不同)、Dock 隐藏→显示、外部移动窗口(windowDidMove idle,908)时会破,仍会位置驱动缩窗。

`PanelLayout.allowedFitHeight`(1018-1023):

```swift
static func allowedFitHeight(
    roomBelowTop: CGFloat, currentHeight: CGFloat, screenCeiling: CGFloat,
    minHeight: CGFloat, chrome: CGFloat, resultFloor: CGFloat = 0
) -> CGFloat {
    Swift.min(screenCeiling,
              Swift.max(roomBelowTop, currentHeight,
                        Swift.max(minHeight, chrome + resultFloor)))
}
```

- `currentHeight` 不给默认值(强迫 call site 表态);refit call site(651-657)传 `panel.frame.height`;
- 更新 641-648 注释:"位置只能抬高不能压低 allowance;唯一例外是 screenCeiling(换更小屏)。allowed 是 desired 的上限,内容驱动收缩不受影响。"
- `min(screenCeiling, ...)` 保证换小屏仍兜底收缩;OCR recognizing(floor=0 紧贴 chrome)、新 run parked-at-bottom 的 need-driven 抬升(`max(minHeight, chrome+resultFloor)`)均不受影响——已逐项核查。

### 不改的东西

- 触顶:零特判(A+B 后自然消失)。
- 双击 reset(`resetPanelPosition`,609-619):移回默认位后一次性展开,显式手势,保留。
- ResultListView / PageModeView:纯 budget 函数,budget 稳则静止;page mode 单块输出无均分问题,天然免疫,不改。
- settle 双跳(finishWindowDrag 759-777)、windowDidMove idle refit(908)、4pt jitter guard(693):不动——修复后 settle refit 计算出 `desired == 当前高度`,被 4pt guard 直接 return,**零 setFrame**,闪烁源头消失。

### 已知行为取舍(与用户确认过的方向一致,落地后可再调)

1. **底部打字让位方式变化**:窗口贴底时输入区变高,棘轮使卡片 body 不再压缩,改为外层结果列表 `listViewportHeight = min(stack, budget)` 收缩出滚动条。同为"结果区让位内滚",滚动条层级不同;若坚持 body 压缩需给 budget 打"内容驱动"标记穿透卡片,复杂度不值。
2. **高度向上棘轮**:拖上长高后再拖回底,窗口停在已达到的高度不回落——这是"禁止位置驱动缩小"的字面后果,与需求一致。

## 测试(`Tests/PanelLayoutTests.swift`,无新文件,不需 xcodegen)

- 既有 7 处 `allowedFitHeight` 调用(142-215)补 `currentHeight: 0` 保持原断言。
- allowedFitHeight 新增:roomBelowTop < currentHeight → 取 currentHeight;flush(相等)→ 恒等;currentHeight > screenCeiling → ceiling 赢;小窗 + needFloor → 仍抬升。
- bodyHeight/effectiveBodyCap 新增:cap 降不裁已渲染 body;measured 变短压过棘轮;dragged 分隔线穿透棘轮;cap 升照常长;measured=nil 等价旧行为。
- **回归不动点测**:构造不等高双卡的精确 budget,断言各卡 `bodyHeight(displayed:)` 在均分 cap 下不变(把根因推演固化)。
- 组合测:flush 时 `windowHeight(ceiling: allowedFitHeight(..., currentHeight: h)) == h`(settle no-op)。

## 验证

顺序:Step 1 → body 测试 → 手动复现触底缩矮确认修复 → Step 2 → allowed 测试 → 全量。两步独立可各自回滚。

- 单测:`xcodebuild -project DuoTranslator.xcodeproj -scheme DuoTranslator test -only-testing:DuoTranslatorTests/PanelLayoutTests`
- 手动(LSUIElement,computer-use 不可驱动;用 [docs/panel-followups.md](../docs/panel-followups.md) 的分布式通知 + CleanShot 录屏帧分析):
  1. `dev.bobby.duo.debug.translate` 起双引擎翻译制造不等高双卡;
  2. 流式中拖到屏底释放:无缩、无二跳;
  3. 流式结束后 flush-bottom 反复上下拖 ≥3 轮:帧间稳定;
  4. 拖到顶:仅被裁内容单次回涨;
  5. 底部多行打字:窗口稳,外层列表出滚动条;
  6. `debug.pageMode` 底部往返、OCR、双击 reset 回归;
  7. `log stream --level debug` 看连续拖拽的 `面板拖拽: end refitted frame=` 是否恒定(稳定判据)。
