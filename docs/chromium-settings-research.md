# 在 Cio 内显示 Chromium 设置页：实现调研

> 2026-10-08 状态更新：下文保留最初的 CEF/Arc 调研记录。当前 Cio 已转向原生
> Chromium 152 桥接，实际代码复用了 Mori 的两个 MIT BrowserWindow 文件；
> 构建、窗口宿主、Settings 标签页和升级边界见 [引擎说明](../Engine/Chromium/README.md)。
> 原先“只参考 Mori”“先验证 CEF Views”的建议不再代表当前实现。


调研日期：2026-10-07。目标是保留 Cio 的 AppKit/SwiftUI 外壳，让真实的
Chromium 设置页使用 Cio 的同一 Profile，在 Main View 内显示，不弹出独立
Chromium 窗口。

## 结论与证据边界

这是可实现的产品形态。本机 Arc 已验证同窗显示；开源 Mori 提供了直接
嵌入 Chromium WebContents 的代码。当前阻碍来自 Cio 使用的标准 CEF
macOS 子视图接口，不能概括成 Chromium 无法支持。

本次只做实现调研，没有完成 Cio 内嵌设置页。工作区此前的独立 Chrome-style
设置窗口是验证 WebUI 能力的临时实现，尚不满足上述目标。Cookie 持久化和
系统语言初始化属于独立功能，不依赖最终采用哪一种设置页宿主。

## 本机 Arc：实际行为与安装包

- 检查 `/Applications/Arc.app`，应用版本 1.167.1 (88217)。
- 在 Arc 新标签页输入 `chrome://settings/languages`，原版语言设置页出现在
  同一个 Arc 主窗口，保留 Arc 侧栏，没有弹出 Chromium 独立窗口。
- 地址栏显示 `arc://settings/languages`，页面辅助功能树报告
  `chrome://settings/languages`。地址栏别名本身不解释嵌入机制。
- 安装包包含自有 `ArcCore.framework`，其版本为 154.0.8037.98；可见导出类
  包括 `ArcBrowser`、`ArcBrowserContext`、`ArcBrowserContextPreferences`、
  `ArcWebContents` 和 `ArcWebContentsNavigationController`。
- 本次文件和导出符号检查没有发现标准 CEF 发行包或常见 CEF 入口；符号
  缺失不能单独证明其内部从未使用过 CEF。Arc 的具体宿主代码未公开。
- 调研标签页已关闭，没有修改 Arc 设置。

The Browser Company 官方说明 Arc 使用内部 ADK（Arc Development Kit），
为原生浏览器 UI 提供 SDK，Arc 与 Dia 共用这一基础设施。因此能借鉴的是
桥接 Chromium 浏览器能力的架构，不能把 Arc 的效果归因于某个公开 CEF
启动开关，也不能直接复用其私有 SDK。
[官方说明](https://browsercompany.substack.com/p/letter-to-arc-members-2025)

## 开源参考：Mori

Mori 的 ObjC++ 桥接代码使用真实 Chromium `Browser` 与 `WebContents`。
创建标签时指定导航不显示窗口，再获取页面的原生 NSView 并加入自己的
视图。这提供了自有 macOS 外壳承载 Chromium 页面的具体参考；本次是源码
核查，没有在本机编译运行 Mori，也未验证其所有设置项。
[桥接源码](https://github.com/FujiwaraChoki/mori-browser/blob/main/ungoogled-chromium-macos/build/src/chrome/browser/ui/mori/mori_chrome_bridge.mm#L991)

## Cio 当前为什么失败

当前 CEF 固定提交为 `708dc140cbc3286826a8abef89dc23a44ff9ea72`。
macOS 的 `CefWindowInfo.parent_view` 一旦提供，浏览器总是采用 Alloy style；
改写 `runtime_style` 或改为离屏渲染不能避开这一规则。
本地依据：`ThirdParty/CEF/include/internal/cef_types_mac.h`。

CEF 的 Alloy 导航代码拒绝未在白名单中的 `chrome://` WebUI，`settings`
不在当前白名单中。Cio 的运行日志也报告相同拦截。此前创建无父视图的
Chrome-style 浏览器使设置页正常显示，同时产生了用户看到的独立窗口。
[固定版本的导航拦截源码](https://github.com/chromiumembedded/cef/blob/708dc140cbc3286826a8abef89dc23a44ff9ea72/libcef/browser/alloy/alloy_browser_host_impl.cc#L506)

## 可选实现

| 路线 | 原版设置页 | 对 Cio 的影响 | 当前判断 |
| --- | --- | --- | --- |
| CEF Chrome Views，自有窗口内容 | 可以使用 Chrome-style WebUI | 改变窗口归属，研究 AppKit 外壳与 Views 的整合 | 标准 CEF 内值得做小型验证的路线 |
| 定制 CEF，补充设置页所需宿主能力 | 待验证 | 保留现有子视图结构，维护引擎补丁与构建 | 先调查 WebUI 后端依赖，不能只删导航拦截 |
| 直接 Chromium + ObjC++ 桥接，参考 Mori/Arc 的架构 | 有明确参考 | 替换引擎接入层，维护 Chromium 构建和版本升级 | 长期控制力最高，迁移范围也最大 |
| Cio 原生设置 UI，读写 CEF Profile API | 不使用原版页面 | 保留外壳，逐项实现设置与能力检查 | Cookie/语言可走此路，但不是原版设置页目标 |

CEF Views 的 `GetChromeToolbarType()` 可以返回 `CEF_CTT_NONE`，说明使用
Chrome style 不必展示 Chrome 工具栏。但 BrowserView 必须有 Views 宿主；
当前 AppKit 的 `SetAsChild` 不是这一接口。一个 Chrome-style CefWindow
最多容纳一个 Chrome-style BrowserView，可以同时容纳多个 Alloy
BrowserView。Cio 的分屏与标签生命周期必须纳入验证。
本地依据：`ThirdParty/CEF/include/views/cef_browser_view_delegate.h` 和
`ThirdParty/CEF/include/internal/cef_types_runtime.h`。
[CEF Views 接口](https://github.com/chromiumembedded/cef/blob/master/include/views/cef_browser_view_delegate.h)

创建隐藏 Chrome 窗口后直接搬走其 NSView，与直接管理 WebContents 并不等价。
目前没有证据证明这种跨窗口搬运能稳定处理焦点、尺寸、弹窗与关闭生命周期，
不能把隐藏窗口当作已经完成的嵌入方案。

## 建议的下一步验证

优先在独立实验中验证 CEF Chrome Views 是否能承载 Cio 外壳；同时检查定制
CEF 对设置页的必要后端依赖。先避免整个浏览器迁移。实验应满足：

1. 原版设置页出现在 Cio Main View，创建与切换过程没有独立窗口闪现。
2. 使用同一个 Cio Profile，语言修改、Cookie 设置读写及重启保留均有效。
3. 搜索、键盘焦点、弹窗、尺寸变化、分屏和关闭/退出均正常。
4. 保留现有 56 pt 外壳尺寸、原生交通灯、统一玻璃背景和圆角约束。

如果标准 Views 不能保留这一外壳、定制 CEF 的依赖范围又接近全浏览器宿主，
再评估 Mori 式 Chromium 桥接。仓库已有 `Scripts/build_cef_codecs.sh` 可参考
固定版本的引擎构建流程，但它尚未支持设置页补丁；不能直接执行该脚本并
认为设置页问题已解决。
