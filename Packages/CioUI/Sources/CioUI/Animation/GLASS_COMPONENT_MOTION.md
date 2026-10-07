# Liquid Glass component motion

这是后续一级玻璃控件的统一模板，适用于侧栏按钮、导航胶囊和地址胶囊。
玻璃保持系统材质，按钮与编辑器保持原生控件；不绘制替代玻璃，不递归给内部图标套同一套效果。

## 视觉要求

| 状态变化 | 材质与内容 | 几何 |
| --- | --- | --- |
| 出现 | 原生 `materialize`；内容从模糊、透明变清晰、实 | 从中心外侧聚拢到正常尺寸 |
| 消失 | 原生 `materialize` 的移除方向；内容逐渐模糊、透明 | 从正常尺寸向外扩散 |
| 移动 | 保留同一个组件，不重建、不触发消失 | 连续移动至目标，位置不回弹 |
| 变大 | 保留原生玻璃与内容 | 超过目标尺寸向外撑开，再收回 |
| 缩小 | 保留原生玻璃与内容 | 小于目标尺寸向内收，再弹回 |
| 中途改目标 | 保留当前可见状态 | 从 presentation geometry 和当前 spring velocity 继续 |

位置使用临界阻尼 Spring，尺寸使用有回弹的 Spring。标准档位置 response 为 0.195 秒，
尺寸 response 为 0.26 秒、bounce 为 0.22；完成时间使用系统计算的 settling duration。
独立出现/消失标准档为 0.25 秒；随页面进入时，共享 page reveal 开始时捕获的时长与曲线，
与页面并行呈现。扩散比例为 1.12，内容模糊半径为 5 pt。
这些是项目模板参数，全部在 `AnimationValues.GlassComponent`；不是 Apple 官方规定的数值。
时间在启动 flight 时读取速度比例，后续沿用同一时钟，尺寸和回弹不随速度档位改变。

## 系统依据

- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)：
  `GlassEffectContainer` 协调玻璃；`glassEffectID` / `glassEffectTransition` 在视图增删或动画时生效。
  官方建议统一使用 `matchedGeometry` 和 `materialize`；材质动画包含超出透明度变化的效果。
- [GlassEffectTransition.materialize](https://developer.apple.com/documentation/swiftui/glasseffecttransition/materialize)：
  支持内容淡入和玻璃材质出现/消失，不尝试把不同控件的几何互相配对。
  本模板选择 materialize，让导航和地址胶囊各自聚拢/扩散，存活控件另行移动。
- [Spring](https://developer.apple.com/documentation/swiftui/spring)：
  使用公开的 Spring 计算位置、速度和稳定时间，支持中途重定向；与 Spotlight 使用系统弹簧展开的原则一致。
- [Build an AppKit app with the new design, WWDC25](https://developer.apple.com/videos/play/wwdc2025/310/)：
  原生工具栏按逻辑分组共享玻璃，玻璃具有自适应外观；AppKit 容器还提供合并和共享采样。
  本项目在自定义 shell 中保留 AppKit 按钮，通过 SwiftUI 系统玻璃接入公开 materialize。

官方文档定义 API 与材质行为，没有承诺某个模糊半径、扩散比例或唯一的回弹曲线。
向内聚拢、向外扩散与双向尺寸回弹，是本项目在这些系统能力之上固定的视觉约束。

## 组合顺序

1. 保持原生按钮/编辑器及它的交互状态挂载。
2. 内容应用 `GlassComponentContentVisibility`（模糊、透明度）。
3. 添加 `ToolbarGlassSurface` 背景：保持容器与 namespace 存活，只有原生玻璃随可见性插入/移除，使用 `.materialize`。
4. 整个组件应用 `GlassComponentVisibility`（从中心聚拢/扩散），并禁止隐藏时交互与辅助功能命中。
5. 外部宿主的布局使用 `GlassComponentLayoutMotion`，与可见性分别管理。不要把整个玻璃父视图 opacity 动画到零。

```swift
nativeContent
  .modifier(GlassComponentContentVisibility(isVisible: presentation.isVisible))
  .background {
    ToolbarGlassSurface(presentation: presentation, cornerRadius: radius)
  }
  .modifier(ToolbarComponentVisibility(presentation: presentation))
```

布局先捕获、再提交最终 frame、最后启动 compositor flight：

```swift
let source = motion.capture(host)
host.frame = destination
host.layoutSubtreeIfNeeded()
motion.animate(host, from: source, enabled: shouldAnimate)
```

父视图也要移动时，必须在修改父坐标系前捕获。捕获使用窗口坐标，最终再转换到新的父坐标系。
重复布局时，相同目的地不截断仍在运行的弹簧；尺寸最后一个采样固定为目标，避免移除动画时尾部修正。

## 分屏交接

- 预览开始/取消：存活的 page 和 toolbar 各自沿可见 presentation 继续布局，toolbar 不隐藏。
- 确认分屏/切换组合：先设定 incoming page 的 reveal 时钟，再一次性应用 placement。
- Incoming toolbar 在 page reveal 开始时并行 materialize，共享该次 flight 捕获的时长与曲线。
  拖拽交接前保持隐藏；交接时先挂载并布局隐藏宿主，再在同一交接事务中启动 page 和 toolbar。
  已预备的页面 toolbar 不额外派发到下一次主队列；完成回调只清理，不再触发出现动画。
- Outgoing toolbar 在原位置扩散。重复 hide 不撤销正在运行的原生材质移除动画。
- 页面动画结束比尺寸弹簧更早时，不清除 toolbar 的独立布局动画。
- 单页 tab 普通切换保留即刻替换同一 slot 的既有行为；交通灯不参与自定义可见性动画。
- Reduce Motion：几何立即就位，取消扩散缩放与内容模糊，玻璃用 `.identity`，状态立即更新。

## 录屏定位（2026-10-06）

原录屏长 9.99 秒、4096×2196，标称最高 120Hz，但为可变帧率，共 518 个真实帧。
按 120Hz / 8.33ms 拆出 1199 个采样进行检查，重复采样不是新增的真实帧。

- 约 1.00 秒：页面预览开始挤压，导航胶囊和地址胶囊在相邻采样中直接切换到右侧最终位置与宽度。
- 约 2.44 秒：incoming 左侧 toolbar 从无到完整状态，没有连续聚拢过程。
- 约 5.65 秒附近的 2→3 切换：新旧地址/导航胶囊短暂叠在一起，存活右侧地址栏直接改变位置/宽度。

- 约 7.2 秒附近的 3→2 切换：旧三组 toolbar 消失过程中，新两组直接在目标位置出现，地址文字短暂重叠。

对应修复是共享布局 spring、原生玻璃双向 materialize、内容单独收敛，
以及交接前保留隐藏状态、reveal 启动时同步执行 toolbar materialize。
构建通过只确认实现可编译；视觉结果需以后通过用户请求的 Debug app UI 检查或新录屏确认。


## 同步时序修正（15:41 录屏）

新录屏长 12.451667 秒、4096×2196、587 个真实帧，按 120Hz / 8.33ms 拆出 1494 个采样帧对照。
切换组合与拖拽确认均可看到：页面接近最终尺寸时 toolbar 仍为空，之后才开始聚拢。
原因是原先 `.enter` 一直阻止 chrome 可见，完成回调解除后才启动默认 0.25 秒的 toolbar 动画，
把 page reveal 与 toolbar materialize 串成了两段。

现在取消进入期间的 chrome 隐藏，flight 在启动时捕获一次 duration；页面 transform、
裁剪、玻璃淡出以及 toolbar 可见性共同沿用该时钟。Toolbar 使用同一条 page reveal easing，
并在隐藏宿主布局完成后立即加入交接事务，不另等 page completion 或主队列 handoff。
快速切换中反向恢复的 layout flight 也提供同一时钟，隐藏 toolbar 不退回独立时序。
预览期间未提交的新 pane 仍保持隐藏；存活 toolbar 的移动和尺寸弹簧保持独立。

## 22:56 录屏：按钮交互与中途布局

录屏长 6.765 秒、4096×2196，共 323 个真实帧；按 120Hz / 8.33ms 拆为 812 个采样。
重点逐帧对照 0.65–1.25 秒的 hover、1.2–1.8 秒的收起和 3.0–3.6 秒的展开：
hover 背景在圆形内显示矩形；收起时侧栏按钮与导航胶囊重叠，展开时按钮短暂消失并出现在绿灯旁。

自定义 shell 没有 NSToolbar 的交互环境。侧栏按钮使用 `.glass` bezel 与 `.circle` borderShape，
由系统处理 hover、按压和松手回弹。导航按钮最初也采用各自的 `.glass` bezel，
但 23:13 截图显示两块圆形材质的接缝；共享背景不能合并独立的 AppKit button bezel。
导航现在使用一个持续挂载的 AppKit 原生按钮容器，内含两个独立 NSButton，
显式设定 72×36 pt 后由一个系统 `.regular.interactive()` Capsule 包裹。
各自保留 action、enabled、help、键盘与辅助功能行为，按钮不绘制独立 bordered bezel；
材质隐藏时使用 `.identity`，保留按钮容器、玻璃 identity 与 namespace，并应用原生 `.materialize`。
内容单独聚拢 / 扩散；导航不再叠加 `ToolbarGlassSurface` 或独立 AppKit glass bezel。
两端 1 pt 留白与总宽度 74 pt 继续由共享 shell metrics 定义。

连续布局不能依赖尚未提交或仍滞后的 backing-layer presentation frame。
在同一事务内启动 flight 后立即重定向，旧实现把 model destination 当作当前位置，检查得到 120 pt 跳变。
现在 geometry、velocity 和 compositor keyframes 都从同一个窗口坐标 flight、同一个捕获时钟采样，
即使 presentation layer 尚不存在，也不会跳到中间终点。保持相同终点的完成通知不取消 flight。
`GlassComponentLayoutMotionTests` 覆盖提交前捕获、同事务重定向和相同终点完成通知；
构建及这些检查不代表原生 hover / 回弹已通过屏幕视觉验收。


## 工具栏尺寸约束与 Debug 实机检查（2026-10-06）

用户 23:21 截图中的胶囊确实比圆形侧栏按钮更扁。原因是只固定了外层 host 的 36 pt 高度，
macOS 原生 GlassButtonStyle 仍按自身的 intrinsic cross-axis 尺寸绘制玻璃。
`buttonSizing(.flexible)` 只约束 primary axis；macOS 中是宽度，不能据此推断玻璃高度。
`glassEffectUnion` 会沿共同 shape 合并：把 shape 改成 Circle 会得到组级圆形，不能用它补救胶囊高度。

最终实现先固定原生 action container 的 72×36 pt frame，再对整个容器应用一次系统
`.glassEffect(.regular.interactive(), in: Capsule())`。它不是不响应事件的背景；
两个持续挂载的 AppKit 按钮在两个 36×36 pt slot 中保留各自的 action、enabled、help 和 accessibility，
不绘制独立玻璃 bezel。玻璃身份、native materialize 和 first-level motion 作用于整个胶囊。
Host 的宽度是 74 pt，两端各 1 pt；所有尺寸集中在 `BrowserShellLayout.swift`。
侧栏按钮也改为直接使用 `BrowserLayout.chromeControlSize`，不再借用地址栏高度。

验收中的独立 SwiftUI Button / 每按钮 NSViewRepresentable 方案曾在导航或窗口恢复时卡住，
采样主线程显示 AppKit key-view-loop 遍历进入 SwiftUI FocusNavigationSequence 后持续循环。
切换为单一 AppKit NSViewRepresentable 容器后，启动和同一组 Back/Forward 操作恢复正常；
无需关闭按钮的键盘焦点或辅助功能。导航动作也在 Chromium 切换文档前把键盘交回稳定页面容器。
这个观察只说明该宿主组合下的实机结果，不能据此声称所有 SwiftUI Button 都有此问题。

本次按照仓库规定构建、结束旧验收进程，并通过绝对 Debug app 路径启动和连接新实例。
Computer use 已检查：

- 单页和双页的静止状态：圆按钮与完整导航胶囊等高，导航没有接缝或两个独立圆形背景。
- 临时页面 `example.com → iana.org`：Back / Forward 点击正常，独立 enabled 状态随历史更新。
- 指针停在启用的 Back 上：系统玻璃出现局部高光，胶囊仍完整且没有矩形 hover 板。
- Sidebar 收起和展开：圆按钮、胶囊保持相同静止高度，返回既有锚点并保持间距。

现有 computer-use 接口不能单独保持 mouse-down 并采集 120Hz 的按压 / 回弹序列；
因此上述检查不等于新动画每一帧的 120Hz 录屏验收。按压反馈仍由原生 NSButton 与系统 interactive glass 处理。
尺寸、形状、锚点和状态更新规则已经加入根目录 `AGENTS.md`，后续更改必须同时保留。

Apple 参考：
[ButtonSizing](https://developer.apple.com/documentation/swiftui/buttonsizing)、
[glassEffectUnion](https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:))、
[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)。
