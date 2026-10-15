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
- `Native/CioHostedMessagePump.*` 继承 Chromium 的 CrApplication 消息泵，
  保留原生菜单的私有 run-loop 模式注册与事件期间的 autorelease 保护。
  显式 Chromium Run 只处理 CF sources；退出嵌套菜单时延后停止当前 pass，
  不停止 Cio 的 NSApplication 主循环。组件构建补丁导出继承所需的三个符号。
  UI pump 工厂仅在主线程创建宿主消息泵；后台 UI 线程使用标准 NSRunLoop pump。
- `Native/CioBrowserWindow.*` 连接已有 Cio NSWindow，阻止创建 Chromium 自有外壳。
  这两个文件从 Mori 的 MIT 实现修改而来；未导入 Mori 的 SwiftUI 应用。
- `Native/BrowserBridge.mm` 将页面视图嵌入 Cio 容器，转发导航、标题、图标、
  加载、证书、关闭和下载事件；原始弹窗 WebContents 被移入 Cio 标签页。
  活跃页面的 favicon 观察 Chromium `ContentFaviconDriver`，将已选取、解析和
  缩放的原生 NSImage 交给地址栏和侧栏，保留多分辨率位图与动态更新。
  导航提交时刷新图标，WebContents 销毁前解除观察。不使用 URLSession 再次
  下载活跃页面图标，避免丢失网页会话或由 AppKit 错误解析 SVG 的内嵌 CSS。
- `NativeLoader/ChromiumProcessHost.mm` 提供不包含 Chromium C++ 头文件的生命周期
  接口，并在首次使用时复制旧 CEF profile。迁移保留旧目录，拒绝复制正在使用的 profile。
- 用户目录为 `~/Library/Application Support/Cio/Chromium/Default`；
  `CIO_DATA_DIR` 可用于隔离开发数据。持久化包括 session cookie，但仍受 Chromium
  的 cookie 过期和清理策略约束。系统语言仅用于第一次初始化，以后尊重 Chrome Settings 的修改。
- `chrome://settings`、语言、cookie、站点权限与隐私设置使用相同 Profile，
  作为普通 Cio 标签打开。
- Extensions 菜单在 Cio 标签中打开 `chrome://extensions/` 或 Chrome 应用商店。
  安装仍使用 Chromium 的商店 API、权限确认、CRX 验签及 Profile 中的扩展目录；
  普通安装通过 `CioExtensionInstallRequest` 把名称、权限及全部详细说明交给
  `CioUI/ExtensionConfirmationSheet`，以系统 Liquid Glass、原生按钮和滚动列表呈现。
  引擎持有原始 prompt 和一次性回调，保留防误触等待、遮挡检查及取消语义；
  原标签、主窗口或 Profile 关闭时取消请求。图标暂用 SF Symbols 占位。
  `Native/CioExtensionUI.*` 对家长批准、企业审批等特殊确认继续使用 Chromium
  原始窗口，并挂到 Cio 主窗口的 AppKit sheet，避免原生标题栏遮挡内容。
  安装结果提示也接到 AppKit，避免访问不存在的 Chrome 工具栏。
  移除确认由 `Native/CioExtensionRemoval.*` 继承 Chromium 原卸载对话框，保留
  卸载策略、指标、举报选项和原始 delegate，只把确认界面交给同一玻璃组件。
  安装与移除均通过 AppKit 的 sheet 定位回调在主窗口内容区域居中。
  安装成功请求提交 Profile 偏好；正常退出先等待偏好提交，再刷新 Cookie 和关闭引擎。
  扩展启用状态与权限由 Chromium 自身保存，不另建 Cio 扩展清单。
- 地址栏图标展开的网站信息包含当前标签页的扩展网格，以及管理和商店入口。
  `Native/CioTabExtensions.*` 观察 Chromium 的 registry、action dispatcher 和图标变化，
  使用 `ExtensionActionViewModel` 执行点击和 activeTab 授权。弹窗和侧栏保留真正的
  `ExtensionViewHost`、popup/side-panel view type 与所属 Browser；AppKit 承载 transient
  popover 或标签页右侧面板，支持 `action.openPopup`、`sidePanel.open/close/setOptions`。
  隐藏标签页会关闭弹窗、隐藏侧栏；卸载、停用或关闭标签页时释放对应宿主。
- `chrome.tabs.create` 的页面在扩展返回值与 opener 设置完成后，接管原始
  WebContents 到 Cio 的受管标签页，保留 Chromium 标签 ID；前台/后台请求沿用
  源 Space 的选择策略。避免扩展创建的页面只留在内部 Chromium 标签栏。
- Native Messaging 保留 Chromium 的主机清单、允许来源、可执行路径与企业策略检查。
  在 Cio 自有目录和 Chromium 系统目录均未注册主机时，仅宿主 macOS 进程继续查找
  标准 Chromium / Chrome 用户注册目录，以及 Chrome 系统注册目录。禁止用户级
  主机的策略同样作用于这些回退目录。清单由桌面应用安装并更新，Cio 不复制清单、
  生成厂商私有注册表或假定桌面应用的安装路径。ChatGPT 扩展还需要桌面端完成
  浏览器连接注册；仅安装桌面应用并不保证已注册 `com.openai.codexextension`。
- 外部协议链接仍先通过 Chromium 的协议、来源和用户手势检查。需要确认时，
  `Native/CioDialogs.mm` 使用原生 AppKit sheet，保留本地化提示、默认取消、
  按来源记住选择和原始启动逻辑；请求页面导航或销毁时取消。避免 Chrome Views
  子模态窗口依赖不存在的 NativeWidgetMac 父窗口而闪退。

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
Views 气泡没有全部映射到 AppKit。密码建议、保存／更新、生成和跨站确认已接到
原生 AppKit controller 适配层；Apple 官方扩展使用系统 Native Messaging 宿主。
实现、授权边界、隔离测试及尚未执行的真实填充验收见 [PASSWORDS.md](PASSWORDS.md)。
DevTools 使用 Cio 容器，当前固定为停靠模式。

## 验证记录

2026-10-14：ChatGPT favicon 的 SVG 带有内嵌 CSS。AppKit 接受该图像，但
绘制得到 0 个可见像素；相同资源经 Chromium 解码的 32 px 缓存有 459 个
可见像素。独立请求备用 `/favicon.ico` 返回 403，无法补救透明 SVG。
活跃页面现使用原生 favicon driver 的 NSImage，不重新下载或用 AppKit 解析 SVG。
`python3 Scripts/verify_favicon.py` 在临时 profile/mock keychain 的 Debug Cio
中加载本地 CSS-styled SVG，验证实际 session 图像的像素与 CSS 颜色：
576 个可见像素、样式正确、正常退出。Debug 构建通过；新 Debug 实例
（PID 35048，21:18:50 启动，绝对可执行路径已核实）的 computer-use 检查确认
ChatGPT 分屏地址栏、置顶分组图标显示正常，刷新与侧栏收起后仍显示。
记录与日志位于 `build/verification/favicon/`。

2026-10-14：chatgpt.com 的 Renderer 崩溃定位到 Chromium 152 的
`CSSVariableParser::StripTrailingWhitespaceAndComments`：嵌套 `var()` 替换空值
后，合法备用值可能以空格开头；含 `/` 或 UTF-16 内容的慢路径却断言不存在
开头空格，导致进程中止。构建补丁保留备用值空格，将该断言移回已调用
`ConsumeWhitespace` 的声明解析处，不改变 CSS 解析结果或关闭其他断言。
`python3 Scripts/verify_css_variable_fallback.py` 启动已构建的 Debug Cio，使用
临时 profile 和 mock keychain 加载实际 HTML fixture，检查计算样式、页面完成
加载和 Renderer 存活；覆盖空变量替换、斜杠、尾部注释和中文备用值。
Debug 构建与回归均通过，日志位于 `build/verification/css-variable-fallback/`。
新构建的 Debug 实例（PID 23968，20:43:07 启动，仓库内绝对可执行路径已核实）
完成实际站点 computer-use 验证：打开 chatgpt.com、普通刷新和强制刷新后均
显示首页、模型选择器和输入框；系统日志未记录该实例的 Renderer 退出。

2026-10-12：针对 `FindContentsWebView → SadTabController → SadTabHelper`
的主进程闪退，宿主模式的 sad-tab 容器查找直接返回空，保留 Chrome 原有查找
和断言；页面退出仍由 BrowserBridge 通知 Cio 已有的错误提示和 Reload 按钮。
`python3 Scripts/verify_renderer_crash.py` 编译引擎实际查找函数，使用有原生窗口、
无 Views BrowserView 的 fixture：修复前在 `browser_view` 断言处中止，修复后通过，
同时覆盖重复查找和普通 Chrome 容器。此检查不启动应用，不代表端到端恢复验收。

同日渲染进程日志出现 `CODESIGNING / Invalid Page`。打包脚本改用临时文件与
同目录原子替换发布组件库和修改过 rpath 的镜像，避免 `copy2` 原地截断旧进程
已经映射的 vnode。`python3 Scripts/verify_runtime_image_copy.py` 使用实际打包函数
和内存映射 fixture；修复前旧映射字节被改写，修复后连续两次替换都保留旧映射、
更新目标内容并保留执行权限。构建中的整个 app bundle 仍不是事务式发布；
正在运行的旧实例应在构建后退出并重新打开。

语言下拉菜单回归检查：`python3 Scripts/verify_hosted_message_pump.py`。
它使用应用实际的宿主消息泵源码与固定 Chromium base 库，覆盖菜单作用域
反复进入、模式恢复、菜单期间任务执行、主线程/后台 UI 线程工厂分流，
以及嵌套原生循环中的延后退出。
2026-10-08 修复前，该检查触发 `DCHECK failed: g_app_pump`；用户语言设置页
的原生 `<select>` 同样在 `ScopedPumpMessagesInPrivateModes` 处中止。
原先继承 CFRunLoop 消息泵没有注册 Chromium 的应用菜单泵，这是宿主接入
缺陷；仅打开设置页的旧 smoke check 无法覆盖点击原生下拉框的路径。
修复后 Debug 构建和上述回归检查通过；
`python3 Scripts/verify_native_runtime.py --mock-keychain` 的六组检查全部通过。
新构建 Debug 实例的 computer-use 验收通过：翻译目标菜单打开、选择简体中文、
取消后再次打开、正常退出与重启保留；普通 HTML `<select>` 的鼠标/键盘选择
及 `onchange` 均正常。验收后已恢复原来的 English 翻译目标和语言设置页。
本轮构建、回归与运行日志在 `build/verification/hosted-message-pump/`。

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
