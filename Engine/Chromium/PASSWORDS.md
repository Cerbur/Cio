# Cio 密码集成与验收边界

## 日常可用路径补齐（2026-10-13）

Chromium 本机密码管理是新 Profile 的默认路径。已有明确的 Apple／Chromium／
关闭选择不会被替换；没有明确选择但已安装 Apple 扩展的 Profile 保留 Apple，
已有关闭保存设置的 Profile 保留关闭。初始化后的选择保存在引擎 Profile 中。
Apple 连接失败不会触发自动换库；设置中提供显式的本机密码管理选择。

- **Passwords → Manage Passwords…** 打开同一 Profile 的原密码管理页面。
  **Save or Update Password…** 重新打开当前页面仍有效的保存、更新或生成密码
  补充账号提示；没有待处理请求时打开管理页面。不缓存秘密或旧文档回调。
- 更新提示的“暂不”使用原 `OnNoThanksClicked`，保存提示使用
  `OnNotNowClicked`；修复更新状态误调用保存回调触发 Chromium CHECK 的崩溃。
- 保存／更新拒绝空的非联邦密码；账号与安全密码编辑器的真实 IME 组合期间
  不接受 Return 提交。跨站提示另外显示原 controller 的凭据来源。
- 自动保存生成密码后，缺少用户名的状态使用原 `AddUsernameBubbleController`
  补充账号并关联原记录；更新成功状态显示原生确认。密码生成仍使用原引擎。
- 账号选择在系统身份认证期间保持 mounted。取消／失败后可重试或取消请求；
  认证进行中拒绝重复选择，关闭、导航及 provider 变化撤销迟到认证。
  首次自动登录提示也由 AppKit 承载，保留原开关和 controller 回调。
- 建议选择若同步销毁 popup，宿主不再访问已销毁对象，并向上游返回失败；
  强密码状态更新不会在紧接的 bounds 更新前提前销毁 controller。
- 正常退出的已有持久化边界并行等待 Profile 偏好、Cookie 和已创建的密码库。
  密码库屏障排在加密／数据库初始化和已提交写入之后，在同一后台序列回到
  主线程后才允许引擎退出；不读取凭据，不通过等待固定秒数推断写入完成。
  解除“此网站不保存”的读→删除链路也必须完成；原完成回调引发的新写入或
  新解除操作同样排在屏障之前。
  此屏障保证排队操作完成，数据库写入是否成功仍由上游处理；它不是保存成功
  的额外断言，也不保证强退前尚未完成的写入。未使用的密码库不会因为退出而
  被创建。

本轮验证结果见文末。以下 2026-10-12 的实现／诊断记录保留为历史证据；实际
网站填充和真实系统认证仍需单独验收。跨设备 Passkey 后续已验收的部分见
[daily-readiness.md](../../docs/daily-readiness.md)，与密码保存／填充分别记账。

本轮日期：2026-10-12。引擎固定为 Chromium **152.0.7977.83**，提交
`79460ebecaa5625e57a5fb679a735659e73dc687`。

本轮只做源码／系统注册信息检查、编译和不接触密码数据的命令行测试。
**没有启动 Cio，没有安装扩展，没有改变运行中的真实密码设置；实际填充、
Apple 授权、验证码和写回尚未验收。**

后续启动闪退修复：用户已授权运行与 computer-use 检查。启动回归使用临时
`CIO_DATA_DIR`、`--use-mock-keychain`，不使用真实密码 Profile。详见文末记录。

**后续 iCloud 连接实测结论：当前 Cio 签名不满足系统 Apple helper 的父进程启动
约束，helper 被 macOS 以 `SIGKILL (Code Signature Invalid)` 终止。Apple 路径
目前不能实际使用；须取得 Apple 准入权限后继续验收。详见文末连接诊断。**

## 已有能力与接线

| 路径 | 固定版本已有能力 | 本轮宿主接线 |
|---|---|---|
| 官方扩展安装、启用、持久化 | 商店 API、CRX 来源与签名校验、ExtensionRegistry、Profile Preferences、退出提交 | 沿用已有安装／卸载确认和 Profile 持久化；不维护第二份扩展清单 |
| Apple native messaging | 清单搜索、allowed_origins、企业策略、stdio framing、管道与进程生命周期 | 沿用 Cio 已有标准 Chrome/Chromium 注册目录回退；增加真实传输状态、一次连接与手动重试、旧连接 epoch 防污染 |
| Apple 账号／密码／OTP／保存更新 | 官方扩展的 service worker、all_frames content script、completion_list、加密配对与 Apple helper 协议 | 保留原版扩展与系统 helper；增加路由文档检查，不解密或复制 Apple 库；不实现私有配对、TOTP 算法或替代写回 |
| Chromium 保存／更新 | ChromePasswordManagerClient → ManagePasswordsUIController → SaveUpdateBubbleController → PasswordFormManagerForUI | 原生 AppKit 账号／安全密码编辑器、网站来源、保存／暂不／此网站不保存；仍由原 controller 关联记录、写库和报告交互 |
| Chromium 账号建议／选择／填充 | PasswordAutofillManager、AutofillPopupControllerImpl、原 suggestion delegate 与 renderer agent | 原生按钮列表与滚动、上下键循环、Return/Esc、子菜单；调用原 SelectSuggestion/AcceptSuggestion，保留误点击等待、跨站确认、授权与 frame 校验 |
| Credential Management 账号选择 | CredentialManagerDialogControllerImpl 与一次 credentials callback | 原生 AccountChooserPrompt，保留原 controller、取消和系统 reauth |
| Chromium 强密码 | 原 generation helper、生成器、预览、renderer generation agent、预存及提交后保存 | 原生 PasswordGenerationPopupView；此版本默认依赖密码同步，Cio 的本机 save-enabled 模式解除该依赖，保留可保存检查、站点限制及原生成算法，无云同步 |
| 管理页面 | 此版本的 `chrome://password-manager/passwords`、密码私有 API、原 store 与 DeviceAuthenticator | 设置中直接打开相同 Profile 的页面；查看／搜索／编辑／删除／导出仍经上游 API，未另做可绕过身份验证的密码编辑器 |
| 存储和钥匙串 | PasswordStore、OSCrypt、Cio Safe Storage/Cio、仓库签名配置 | 不改加密、存储位置或签名方式；密码保留跨重启，更新后的钥匙串授权稳定性取决于现有签名身份 |

表中的“接线”是实现状态，不是端到端实际填充验收结论。

## Apple 官方扩展及系统证据

静态检查的是指定官方商店 ID `pejdijmoenmkgeppbflobdenhhabjlaj` 的 **3.4.0**
CRX。manifest public key 推导出的 ID 与指定 ID 一致。下载仅存于临时目录，
没有加载到任何浏览器。该下载的 SHA-256：
`610ddd342cab1f66c317da9a24206839829a7ba10376afbb21c94781c3d84f26`。
安装仍必须通过 Chromium 商店路径验签，以上静态检查不能替代安装校验。

本机只读取了 `/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json`
中的注册元数据：

- name：`com.apple.passwordmanager`
- type：`stdio`
- executable：`/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper`
- allowed_origins 包含 `chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/`
  及 Apple Edge 扩展来源。
- helper bundle ID：`com.apple.PasswordManagerBrowserExtensionHelper`，版本 **27.0.1**。

Chromium `LaunchContext::FindManifest` 查找该清单；`LaunchContext::Launch`
保留清单格式、来源、绝对可执行路径、用户级主机策略与访问检查；
`LaunchNativeProcess` 保留原管道和 macOS responsibility disclaimer。
Cio 没有伪装为 Chrome/Edge、修改 Apple 程序、复制清单或读取密码数据库。

初次接线只检查了 helper 的 Chrome／Edge 静态字符串，这本身不能证明 Cio 被拒绝。
当时未启动 helper 或配对；后续用户运行产生了文末所列的真实系统拒绝报告。
实际失败时请检查扩展和 Cio 设置中的状态：

| 实际接口结果 | 反馈 |
|---|---|
| `RESULT_NOT_FOUND` | `Specified native messaging host not found.` |
| `RESULT_FORBIDDEN` | `Access to the specified native messaging host is forbidden.` |
| `RESULT_FAILED_TO_START` | `Failed to start native messaging host.` |
| EOF／IO 错误 | `Native host has exited.`／`Error when communicating with the native messaging host.` |
| 过期文档／填充目标改变 | `Cio canceled an obsolete iCloud Passwords request/response...`；需要手动重试 |

设置中的“通道已建立”只表示 `RESULT_SUCCESS` 后管道建立，**不表示已解锁**。
授权取消与 helper 的浏览器身份拒绝可能都表现为 EOF，Cio 不捏造无法分辨的原因。
原版扩展的退出后自动 reload 不会无限启动 helper：连接失败后必须由用户在设置
中手动重试。旧连接的迟到 callback 不能改变新连接 epoch 的状态。

原版扩展用 `(cmd, tabId, frameId)` 传递账号查询、填充和 OTP 查询，缺少 document ID。
Cio 只解析外层路由字段，保留真实 WebContents／frame 的 WeakDocumentPtr；
导航、销毁和填充期间的 pane 切换会撤销目标。在仍有旧请求时，不把该路由重绑到
新文档。无法安全关联时关闭连接并提示手动重试，而不是向新页面投递晚到的结果。
密码及验证码内容、SMSG 和配对内容保持原版协议，本轮不记录它们。
写回依然由 Apple 自己发起和完成；没有 Cio 侧密码库写入 API。

## 选择和启用

打开 **Cio 设置 → 密码管理**。唯一偏好在 Chromium Profile 中注册为
`cio.password_provider`：0 Apple、1 Chromium、2 关闭；不镜像到 UserDefaults。
新 Profile 默认 Chromium；已有选择的保留规则见本文首节。

- **Apple iCloud 密码扩展**：点击官方扩展入口，由你安装并在扩展管理中启用。
  打开网站信息里的扩展操作，按 Apple 弹窗授权／配对／解锁。停用或卸载后保持
  Apple 选择并显示状态，绝不切到 Chromium 库。需要时点击“手动重试 Apple 连接”。
- **Chromium 内置密码管理**：停用 Apple 扩展，打开标准
  `credentials_enable_service` 保存设置，并让 ChromePasswordManagerClient 的
  IsFillingEnabled 与原 driver 最终填充路径读取当前 provider。已有密码不删除。
- **关闭密码保存与自动填充**：停用 Apple 扩展，关闭上述密码保存、填充和
  Credential Management 自动登录；保留所有已保存记录。

切回 Apple 后需手动重新启用扩展；Cio 不擅自恢复被用户／策略禁用的扩展。
上游密码保存设置的改动会反映到 provider；Apple 的 false privacy override 不会
让 Cio 暗中换库。管理策略冲突会明确报错。

官方 3.4.0 扩展默认还请求关闭地址及银行卡填充。Cio 只拒绝 Apple 对这些偏好的
扩展写入，并清除它先前留下的自身 override，让原用户／企业值重新显现。
不设置或重置地址／银行卡偏好，不影响其他扩展的控制，不删除 Chromium 密码。
Apple 扩展可能在其设置页显示不能完全控制浏览器自动填充，这是 Cio 的明确边界。

首次使用 Chromium 加密存储、查看明文／导出、启用填充前 reauth，可能需要系统
钥匙串、Touch ID 或屏幕锁授权。原机制保持不变。仓库默认是 ad-hoc 签名，重编译
会改变代码身份，因此不能保证跨开发更新永不再次询问钥匙串；使用仓库已有
`CIO_CODE_SIGN_IDENTITY`／`CIO_DEVELOPMENT_TEAM` 固定身份配置可改善此问题。
本轮没有改签名或真实钥匙串设置。

## 生命周期及界面边界

原生密码面板挂在请求 WebContents 的 NSView／窗口，分屏不会用全局当前标签
替代源页面。背景 pane 不展示 Chromium 提示，不抢页面焦点。保存／更新 callback
先消费请求，再调用原 controller；关闭及销毁先断开原生 target 再报告交互，避免
重入二次完成。强密码与建议 controller 仍按各自上游 self-owned 生命周期销毁。

原建议 preview/fill、origin／SSL／iframe 安全校验、身份验证和误点击保护保留。
Touch ID／屏幕锁返回时还会检查源文档、pane 归属及 provider；切标签、导航、关闭
或偏好变化撤销旧结果。driver 的实际填充／生成交接再次查询当前引擎偏好。

建议处理键盘事件前检查 AppKit first responder 的 marked text，中文 IME 正在
组合时把 Return/Esc/方向键交还系统。实际 IME 及原生面板外观尚未进行 UI 验收。
面板使用 AppKit 控件、NSVisualEffectView 和系统窗口行为，没有自定义动画计时，
没有改变 shell、工具栏、traffic lights 或已有原生编辑器。

多账号匹配、分步登录、跨域 iframe、SPA、提交失败识别由原 PasswordManager
处理。本轮没有编写 JS 扫描／填充，也没有用导航即成功的宿主启发式替代提交判断。
这几类网站的真实表现仍需要下面的人工验收。

## Passkey／WebAuthn

引擎仍包含 Chromium 的 WebAuthn／FIDO 与平台认证代码。本轮不实现或验收
Passkey 注册／认证 UI、conditional mediation、跨设备二维码或 iCloud Passkey。
Chrome Views 的相关宿主界面可能仍有缺口；密码建议出现或密码填入均不能证明
Passkey 可用。Apple 扩展的密码／OTP 协议也不能替代 WebAuthn 验收。

## 验证结果与可重复命令

最终从仓库根目录运行 `CONFIGURATION=Debug Scripts/build.sh`，退出码 **0**，
日志结果为 **BUILD SUCCEEDED**，没有编译错误。产物为
`build/DerivedData/Build/Products/Debug/Cio.app`。没有启动该产物；构建脚本检测到的
已有运行实例没有被用于验收，也没有被本轮操作退出或重启。

```sh
# 唯一 app 构建入口，不启动应用
CONFIGURATION=Debug Scripts/build.sh
# 无 Profile／密码库／Apple helper／Keychain 的独立命令行测试
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/verify_password_integration.py
```

测试编译并调用应用使用的 `CioPasswordPolicy.h`，使用虚构 pane／document 和
延迟回调。覆盖 provider 协调与上游设置映射、地址／银行卡隔离、键盘选择、
分屏独立目标、主文档／iframe／SPA 失效、切走再回来、关闭、provider 改变、
重入与一次完成、Apple opaque 路由生命周期、32 个线程竞争连接、终止错误、
手动重试及旧 epoch 迟到回调。**45 项通过**。
这些是关键宿主规则的测试，不能替代真实 renderer、store、Apple 配对或 UI 测试。
日志：`build/verification/passwords/policy-tests.log`；构建日志：`build/password-build.log`。

## 人工验收（尚未执行）

仅在临时 `CIO_DATA_DIR` 和专用虚构账号中验证；Apple 写回用专用测试条目，
不要读取／导出真实密码。各项只有实际观察到对应结果后才能勾选：

- [ ] Apple 官方商店安装、启用，退出／重启后保留；弹窗真实配对／解锁成功。
- [ ] Apple 登录选择账号并填入用户名和密码；OTP 填入专用验证页面。
- [ ] Apple 注册保存、修改后更新，在 Apple“密码”中确认专用条目写回。
- [ ] Apple 标签／分屏、关闭、导航、授权取消及宿主断连：旧结果不进入新页面，
      状态清楚，失败没有无穷重启，手动重试可重新授权。
- [ ] Chromium 同站多账号建议，鼠标和上下键／Return／Esc；中文 IME Return 不误选。
- [ ] Chromium 成功登录保存、暂不、此网站不保存；提交失败不误保存。
- [ ] Chromium 分步登录、跨域 iframe、SPA、修改密码正确关联原账号。
- [ ] Chromium 注册／修改密码生成，接受／取消、实际填入、提交后保存。
- [ ] 原密码页面查看、搜索、编辑、删除专用记录；查看明文／导出保留系统认证。
- [ ] 三种偏好切换和重启后实际状态一致；Apple 停用／卸载不换库，地址／银行卡
      原设置保留，Chromium 专用密码记录仍在。
- [ ] 同一签名下重启／更新后密码可解密；系统钥匙串授权取消得到真实失败。
- [ ] Passkey 另建独立验收；以上密码项全通过也不能勾选 Passkey。

## 启动闪退回归（2026-10-12）

崩溃报告和隔离启动复现均定位到
`ExtensionPrefValueMap::GetExtensionPrefValueMap` 的
`CHECK(i != entries_.end())`，退出信号 SIGABRT（进程退出码 -6）。
`PasswordPreferences::Apply` 在 Apple 扩展不存在时，仍调用了
`RemoveExtensionControlledPref`；该接口要求扩展已在 Chromium 偏好映射中注册。

修复将清理操作限定在官方扩展确实安装后的状态；后续安装加载仍由原 registry
事件触发清理。没有关闭 Chromium 的 CHECK，也没有伪造扩展注册项。
实际调用链回归命令：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/verify_password_startup.py
```

该测试在无 Apple 扩展的临时 Profile 中验证首次启动、窗口／页面加载、正常退出及
同 Profile 重启；修复前已复现相同 CHECK，日志为
`build/verification/password-startup/before-fix.log`。不安装扩展、不授权 Apple helper、
不访问真实钥匙串或密码库。

修复后的仓库 Debug 构建 **BUILD SUCCEEDED**（退出码 0）；原 45 项密码规则测试
仍通过。启动回归的首次启动与同 Profile 重启均通过，页面加载后正常退出。
Computer-use 连接绝对路径的最新 Debug app，并核对唯一 Cio 进程 PID **75984**
及其可执行路径，未复用旧实例。隔离 Profile 的主窗口、密码设置和
Apple → Chromium → 关闭 → Apple 切换均正常；验证实例正常退出，退出码 0。
构建日志：`build/password-crash-build.log`；运行日志：
`build/verification/password-startup/{first-launch,restart,ui}.log`。
这些检查验收启动崩溃修复，仍不构成实际密码／验证码填充或 Apple 授权验收。

## iCloud 连接失败的系统拒绝证据（2026-10-12）

用户运行中的 Debug Cio PID **77032**，官方扩展已安装启用。Computer-use 只查看
引擎连接状态，没有安装扩展、改选密码库、输入认证信息或读取密码。
设置显示 Native Messaging 断连，官方弹窗提示无法连接 helper／需受支持浏览器。

系统崩溃报告：

| 报告 | helper PID | 父进程 | 系统结果 |
|---|---|---|---|
| `PasswordManagerBrowserExtensionHelper-2026-10-12-115424.ips` | 77506 | Cio 77032 | SIGKILL (Code Signature Invalid) |
| `PasswordManagerBrowserExtensionHelper-2026-10-12-115433.ips` | 77537 | Cio 77032 | SIGKILL (Code Signature Invalid) |

`com.apple.passwordmanager` 清单确实允许指定官方扩展来源，宿主文件也存在。
本机 helper **27.0.1** 的签名含 Self 与 Parent Launch Constraints。
只读提取 Mach-O `LC_CODE_SIGNATURE` 中 **slot 9**（Parent Launch Constraint）
的签名 DER，`openssl asn1parse` 显示 `$or-array` 中的接入条件为：

- 父进程拥有 `com.apple.developer.web-browser.public-key-credential = true`；或
- 父进程满足列出的浏览器 `signing-identifier` 与对应 `team-identifier`。
  例如 Google Chrome、Edge、Arc／Dia 等；不是只看浏览器的展示名称。

当前实测构建：`Identifier=com.cerbur.Cio`，`TeamIdentifier=R6GTN68ATQ`；没有
上述 entitlement，也不在这个系统版本的签名身份分支中。两份 arm64 切片都如此。
结合父进程为 Cio 的真实签名终止记录，当前失败发生在系统准入／代码签名阶段，
不是密码库为空、验证码未解锁或扩展无法安装。

合法接入需要 Apple 批准对应权限并以有效 provisioning profile 签名，或由 Apple
支持 Cio 的实际签名身份。Apple [官方 entitlement 文档](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
要求组织开发者账号的 Account Holder 提交 macOS Browsers Passkeys 申请，
Apple 审查后通过 managed capabilities 开通。普通开发者签名本身不足以获得该权限。
此父进程条件得到满足也不等于配对／填充已成功，更不等于 Passkey UI 已验收。
本轮没有添加未获准的 entitlement、修改或重签 Apple 程序、冒用获准浏览器、
从其他浏览器代理密码，也没有绕过系统校验。

可重复运行的只读诊断（不启动 helper，不读 Profile／密码库）：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Scripts/diagnose_icloud_host.py \
  --output build/verification/passwords/apple-host-diagnostic.json
```

产物只含公开签名约束、Cio 签名元数据和以上崩溃的终止元数据；没有原始 native
message、账号、密码、验证码或配对数据。脚本保留实际 ASN.1 证据，不将静态条件
检查伪装为 Apple 授权。扩展已安装／清单来源允许仍不能标记“iCloud 密码可用”。

本次仓库 Debug 构建退出码 0，**BUILD SUCCEEDED**，日志
`build/icloud-diagnostic-build.log`；45 项密码规则测试通过。没有改应用签名配置或
添加权限。用户的既有运行实例用于只读问题诊断，没有作为新构建的运行验收。

## 本机密码路径验证记录（2026-10-13）

- 仓库规定的 `CONFIGURATION=Debug Scripts/build.sh` 最终退出码 0，
  **BUILD SUCCEEDED**，没有编译错误。日志：`build/p0-password-build.log`。
  原生源码复制改为保留新写入时间，修复构建期间编辑文件后 Ninja 可能复用旧
  对象的增量构建问题；Objective-C 接口版本随新增提示入口更新为 4。
- `PYTHONDONTWRITEBYTECODE=1 python3 Scripts/verify_password_integration.py`
  通过 48 项策略／生命周期检查，并编译固定 Chromium 的实际取消、编辑及
  补充用户名方法，验证保存／更新取消分别调用正确 delegate、生成密码关联
  原记录；旧更新取消路径在独立进程中仍命中原 CHECK／SIGABRT。
- `PYTHONDONTWRITEBYTECODE=1 python3 Scripts/verify_password_shutdown.py`
  提取实际 Store／Backend 屏障、初始化完成和解除阻止完成方法，链接当前
  Chromium base。通过初始化前后排队、阻塞写入、FIFO 文件内容、重复屏障、
  后端不可用、多阶段解除阻止、多个等待者和重入完成的检查。四个反向验证
  分别识别提前回复、缺少初始化等待、缺少多阶段等待、错误的完成顺序。
  产物：`build/verification/password-shutdown/shutdown-tests.log`。
- 上述测试没有启动应用、创建 Profile、读取凭据或访问钥匙串。文件写入只含
  临时合成标记，不能替代真实密码库加密／解密、renderer 填充或系统认证验收。
- 按当前仓库默认验证约定，本轮没有启动 Debug app 或执行 computer use；
  真实网站保存→重启→填充→修改密码的端到端界面验收仍未执行。Apple iCloud
  准入限制未改变，也未改动用户正在运行的实例或其密码管理偏好。
