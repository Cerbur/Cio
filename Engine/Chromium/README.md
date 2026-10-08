# Cio 原生 Chromium 引擎

当前构建后端是 `chromium-native`。Cio 的 Swift/AppKit 外壳通过
`CioChromium.framework` 的 Objective-C 接口连接 GN 编译的原生 Browser、
Profile 和 WebContents。原有 CEF 后端、Helper、构建脚本与本地依赖已移除。
只保留旧 profile 的一次性迁移和历史诊断接口名称兼容，不需要安装或链接 CEF。

## 固定版本与构建

Chromium 152.0.7977.83，提交 `79460ebecaa5625e57a5fb679a735659e73dc687`。
官方源码归档与 SHA-256、Mori 实际复用范围见 [upstreams.json](upstreams.json)
和 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)。

```sh
# 首次获取官方源码、固定工具链并编译 stock Chromium；可断点续编。
python3 Scripts/try_chromium_build.py
# 应用版本固定的原生桥接补丁；可单独增量编译引擎。
python3 Scripts/build_native_chromium.py
# 唯一推荐的 Cio 应用构建入口；自动增量构建引擎和打包。
CONFIGURATION=Debug Scripts/build.sh
# 静态检查签名、全部库依赖、原生导出和许可；不启动应用。
Scripts/verify_bundle.sh
```

需要 macOS arm64、Xcode 27 和 Apple Metal Toolchain。需要时通过
`xcodebuild -downloadComponent MetalToolchain` 安装 Metal 工具链。
构建使用四个 Ninja 作业、Release component 配置、关闭调试符号，并保留至少
20 GiB 空间。源码与工具链在忽略的 `build/ChromiumBuild` 内。

## 宿主与数据

- `Native/CioNativeRuntime.mm` 保持 Chromium 的 BrowserMainRunner 和
  ContentMainRunner 存活，将任务调度接到 Cio 的 AppKit 循环，并在页面关闭、
  cookie 刷新完成后依序关闭。BrowserCrApplication 提供 Chromium 所需事件接口。
- `Native/CioBrowserWindow.*` 连接已有 Cio NSWindow，阻止创建 Chromium 自有外壳。
  这两个文件从 Mori 的 MIT 实现修改而来；未导入 Mori 的 SwiftUI 应用。
- `Native/BrowserBridge.mm` 将页面视图嵌入 Cio 容器，转发导航、标题、图标、
  加载、证书、关闭和下载事件；原始弹窗 WebContents 被移入 Cio 标签页。
- `NativeLoader/ChromiumProcessHost.mm` 提供不包含 Chromium C++ 头文件的生命周期
  接口，并在首次使用时复制旧 CEF profile。迁移保留旧目录，拒绝复制正在使用的 profile。
- 用户目录为 `~/Library/Application Support/Cio/Chromium/Default`；
  `CIO_DATA_DIR` 可用于隔离开发数据。持久化包括 session cookie，但仍受 Chromium
  的 cookie 过期和清理策略约束。系统语言仅用于第一次初始化，以后尊重 Chrome Settings 的修改。
- `chrome://settings`、语言、cookie、站点权限与隐私设置使用相同 Profile，
  作为普通 Cio 标签打开。

## 打包与升级边界

当前为开发用 component build：除了 Chromium Framework 和四个上游 Helper，
还必须携带构建产物中的全部 component dylib。打包脚本按清单复制库，重新生成
相对 rpath，签名内部代码，再由 Xcode 签名 Cio。应用不依赖源码构建目录运行。
实际构建生成的 credits、Chromium 许可证和 Mori MIT 许可证随包提供。

引擎可以单独编译，Cio UI 不依赖 Chromium C++ API。升级必须更新固定版本、
源码哈希，重新适配并编译 Native 补丁，再更换完整引擎产物及许可记录；这是
可独立维护的构建边界，不代表任意 stock Chromium 都能直接替换或运行时热更新。
Objective-C 接口改变时也必须同步更新 CioChromium 接口版本和 UI 客户端。

编译启用了 proprietary codecs / Chrome FFmpeg branding，并启用平台 HEVC。
2026-10-08 在 Cio 内实际播放了两个本地测试视频，H.264/H.265 均解码至 2 秒。
这不代表所有视频编码参数或 DRM 内容均支持。此构建不包含 Google 私有
服务或 Widevine。Cio 使用自己的 UI；Chrome 特有的自动填充提示、扩展工具栏等
Views 气泡没有完整映射到 AppKit。DevTools 使用 Cio 容器，当前固定为停靠模式。

## 验证记录

2026-10-08：stock Chromium、原生桥接目标和最终 Cio Debug 构建均成功。
`Scripts/verify_bundle.sh` 确认 519 个组件库、四个辅助进程、dyld 依赖闭包、
原生导出、签名和许可；包内桥接输入哈希与当前源码一致。
本轮日志位于 `build/verification/native-bridge/`。用户明确要求 computer use 后，
已连接新构建 Debug app（绝对可执行路径、独立测试 profile）验收：tab 反复切换、
原始 popup 的 opener 保留、1→2→3 分屏、3→2 关闭中间页、取消分组、独立导航、
侧栏折叠展开、原版 `chrome://settings/languages` 与系统简体中文默认值、
H.264/H.265 实际播放，以及原生 beforeunload Stay/Leave 两个分支。
正常退出记录了 cookies-flushed、shutdown(clean: true)，退出码为 0。
同一临时 profile 重启后 session cookie 和 persistent cookie 均保留。
停靠 DevTools 的 DOM 树可用，关闭后恢复页面。测试下载在 Cio 显示 Completed，
落入指定临时目录且 32768 字节内容逐字节匹配；目录别名、悬空符号链接拒绝、
同名文件避让也通过实际 DownloadManager 源码的隔离驱动。
最终新构建验证了 ⌘L 全选后粘贴导航、双分屏中仅修改当前右页，以及 ⌘W
只关闭当前分屏 tab、保留另一个页面；正常退出码为 0。
`python3 Scripts/verify_native_runtime.py --mock-keychain` 的 normal、page、settings、
repeat、beforeunload-cancel、beforeunload-accept 六组均通过，日志在
`build/verification/native-bridge/runtime-final.log`。

测试 profile 使用临时目录与显式 `--use-mock-keychain`，不读取用户账号数据。
这不验证旧 CEF/Chromium 加密 cookie 的迁移，也不验证真实钥匙串授权。
默认运行仍启用加密并使用 Cio 自己的 Safe Storage 项；开发构建是 ad-hoc 签名，
每次重编译可能改变身份。要使更新后的钥匙串授权稳定，需要固定签名身份。
从 Documents 内启动 ad-hoc Debug app 时还可能遇到 macOS 文件夹授权阻塞；
本轮临时 profile 验收没有修改系统权限。
