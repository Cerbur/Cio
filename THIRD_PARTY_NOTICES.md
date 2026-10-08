# 代码来源、复用范围与第三方许可

Cio 外壳与自有桥接代码使用根目录 LICENSE。第三方实现保留自己的版权与许可；根目录许可证不替代它们。

| 来源 | 实际用途与状态 | 许可 |
| --- | --- | --- |
| Google Chromium 152.0.7977.83 | 使用官方精简源码编译，应用 Cio 的原生桥接补丁，作为当前浏览器引擎打包 | Chromium BSD 及各依赖许可证；实际构建生成的 credits |
| Mori | 复制并修改两个 BrowserWindow 文件，以承载 Cio 的 AppKit 窗口 | MIT，Copyright (c) 2026 Mori contributors |
| Arc | 仅公开资料和本机行为调研；没有复制、链接或分发其实现 | 未使用私有代码或 SDK |

旧 CEF 接入已移除，不作为源码依赖或运行时分发；历史代码可以从 Git 历史查阅。
旧 profile 的迁移兼容和诊断接口名称不包含 CEF 的实现或二进制。

## Chromium 来源与修改

- 上游：https://chromium.googlesource.com/chromium/src.git
- 版本：152.0.7977.83。
- 提交：79460ebecaa5625e57a5fb679a735659e73dc687。
- 官方源码归档、SHA-256 和构建记录见 [upstreams.json](Engine/Chromium/upstreams.json)。
- Cio 补丁源位于 `Engine/CioChromium/Native`，由 `Scripts/build_native_chromium.py` 应用。
- 修改范围：宿主生命周期、BrowserWindow 工厂、弹窗和新标签路由、下载目的地、首选语言注册、会话 cookie 恢复、DevTools 宿主及导出接口。未修改网页的安全策略或下载安全检查。
- 渲染、网络、媒体、WebUI 与 DevTools 均来自 Chromium 及其依赖，不能归为 Cio 原创内核。

## Mori 实际代码复用

- 项目：[FujiwaraChoki/mori-browser](https://github.com/FujiwaraChoki/mori-browser)。
- 固定提交：`b5b29c2e29061f9b2009e8cc0b2756c6ad62bb20`。
- 版权：`Copyright (c) 2026 Mori contributors`。
- 完整许可证：[Mori-MIT.txt](ThirdParty/Notices/Mori-MIT.txt)。

| 原文件 | Cio 目标文件 | 修改范围 |
| --- | --- | --- |
| `ungoogled-chromium-macos/build/src/chrome/browser/ui/mori/mori_browser_window.h` | `Engine/CioChromium/Native/CioBrowserWindow.h` | 重命名；Chromium 152 接口适配；Cio 窗口宿主声明 |
| `ungoogled-chromium-macos/build/src/chrome/browser/ui/mori/mori_browser_window.mm` | `Engine/CioChromium/Native/CioBrowserWindow.mm` | 连接 Cio 现有窗口；焦点与关闭流程；原生主题；DevTools；快捷键；使用原生 AppKit 提示组件 |

这两个文件保留来源、版权和 MIT 许可指引。Mori 的 SwiftUI 外壳、构建脚本和二进制没有被移植。
`BrowserBridge.mm`、`CioNativeRuntime.mm`、`CioRoot.mm`、NativeLoader、构建和打包脚本为 Cio 编写。

## 随应用提供的许可资料

`Scripts/package_native_chromium.py` 将以下资料放入 `Cio.app/Contents/Resources/ThirdPartyNotices/`：

- `Chromium-LICENSE.txt`：实际编译源码的 Chromium 版权和 BSD 许可。
- `Chromium-CREDITS.html`：通过 Chromium 官方 licenses 工具、以实际 GN chrome 目标生成的依赖许可。
- `Mori-MIT.txt`：上述复用代码的完整 MIT 许可。
- `Chromium-BUILD.json`：版本、源码哈希和桥接输入哈希。
- `THIRD_PARTY_NOTICES.md`：本说明。

更换引擎时必须同步更新来源、补丁、生成的许可资料和版本记录。开源许可不自动授予 Google 商标、服务、Widevine 或媒体专利授权。
