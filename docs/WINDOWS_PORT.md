# Windows 移植说明（WINDOWS_PORT.md）

Codex Bridge 的核心逻辑（代理引擎、MCP 网关、服务编排、IPC 协议、存储）自
win 分支起与 macOS 解耦，Windows 目标同时面向 x64 与 ARM64。x64 由 GitHub
Actions 原生编译并运行冒烟测试；ARM64 在同一 x64 runner 上交叉编译和链接。
本文记录平台层的边界、Windows 侧实现与已知限制。

## 架构

```
┌────────────────────────┐        ┌──────────────────────────────┐
│ macOS: CodexBridge.app │        │ Windows: codex-bridge-windows-app │
│ SwiftUI / AppKit 壳    │        │ Win32 + WebView2 壳          │
│ BridgeServiceAppShell  │        │ BridgeWindowsShell            │
└──────────┬─────────────┘        └────────────┬─────────────────┘
           │ BridgeIPC                         │ BridgeIPC
           │  · NSXPC (Mach service)           │  · 命名管道 \\.\pipe\org.codexbridge.service
           │  · XPCServiceTransport            │  · NamedPipeServiceTransport
┌──────────▼──────────────────────────────────▼─────────────────┐
│ 后台服务 codex-bridge-service（macOS: LaunchAgent / Windows: 后台进程）│
│ BridgeServiceHost → BridgeServiceRequestController（传输无关调度）│
│ BridgeServiceApplication / BridgeCodexService / BridgeMCP / …  │
│ —— 与平台无关的核心，两个平台共用同一套二进制逻辑 ——            │
└───────────────────────────────────────────────────────────────┘
```

### 平台接缝（macOS 专属能力 → 抽象 → Windows 实现）

| 能力 | macOS 实现 | 抽象 | Windows 实现 |
| --- | --- | --- | --- |
| Shell ↔ 服务 IPC | NSXPC（launchd Mach service） | `ServiceRequestTransport` / `ServiceStreamSink` | 命名管道（帧格式：kind + u32le 长度 + payload；kind 0 请求 / 1 响应 / 2 流推送） |
| 服务端监听 | `BridgeServiceXPCListener` | `ServiceRequestListener` / `ServiceListenerFactory` | `BridgeServicePipeListener`（每连接一个会话线程 + 请求路由器） |
| 密钥存储 | Keychain（`KeychainSecretStore`） | `SecretStore` 协议 / `SecretStoreFactory` | 凭据管理器（`WindowsCredentialStore`，CredReadW/WriteW/DeleteW，blob ≤ 2560 字节） |
| 内嵌 ChatGPT 页 | WKWebView（`ChatGPTWebView`） | 平台壳各自实现 | WebView2（`WindowsChatWebView`，经 WebView2Loader.dll 的最小 COM 绑定） |
| 桌面 UI | SwiftUI/AppKit（`BridgeServiceAppShell`） | `BridgeServiceAppCore`（跨平台模型层与任务呈现） | Win32 消息循环 + WebView2 + 原生任务检查器（历史/实时对话、Interrupt、Steer） |
| 后台服务注册 | `SMAppService` LaunchAgent | —（Windows 为按需拉起） | 壳启动时探测管道，不存在则拉起同目录 `codex-bridge-service.exe` |
| 文件安全边界 | openat + O_NOFOLLOW 相对 fd 遍历 | `SecureFileReader` / `SecureProjectFileWriter` / `SecureProjectDirectoryMutation` | 逐组件 reparse-point 校验 + CreateFileW（CREATE_NEW / 暂存替换 / MoveFileExW） |
| Provider 路径与工件 | POSIX 路径、fd/stat 身份 | `AgentPathSemantics` / `SecureFileArtifactSnapshot` / `SecureFileArtifactReader` | 盘符、UNC、大小写与 `;` PATH 语义；逐组件 reparse 校验后按句柄读取身份与摘要 |
| Codex app-server 发现 | App bundle / Homebrew / 用户工具目录，最后经 `/usr/bin/env` | `AppServerConfiguration` | `PATH`、用户安装目录与 npm/Bun/standalone 包；`.cmd` 只解析到真实 `codex.exe`，并校验 PE 架构；找不到时明确失败 |
| 代码签名校验 | SecCode（SecStaticCode/SecCode） | `TunnelCodeSignatureVerifier` | 不可用（见下节 Tunnel 限制） |
| SHA-256 | swift-crypto（macOS 上转发 CryptoKit） | `import Crypto` | swift-crypto（BoringSSL 后端） |

## 构建

Windows 使用 Swift 6.3.3 工具链（swift.org 官方支持 x86_64 与 aarch64）：

```powershell
powershell -File Scripts\build-windows.ps1            # 构建服务 + 壳
powershell -File Scripts\build-windows.ps1 -Test      # 附带冒烟测试
```

构建脚本随后会生成以下 portable 目录（`<architecture>` 为 `x64` 或 `arm64`）：

```text
.build/windows-dist/<architecture>/
├── codex-bridge-service.exe
├── codex-bridge-windows-app.exe
├── WebView2Loader.dll
├── swift*.dll / 其他 Swift runtime DLL
├── sqlite3.dll
├── BridgeCore_BridgeDeepSeekHarnessACP.bundle（或 .resources）
├── LICENSE.txt / NOTICE.txt
├── Microsoft.Web.WebView2.LICENSE.txt / Microsoft.Web.WebView2.NOTICE.txt
├── BUILD-INFO.json
└── SHA256SUMS.txt
```

并在 `.build/windows-dist/` 下生成同级
`codex-bridge-windows-<architecture>.zip`。运行壳时若服务未启动会自动拉起；也可手动
`codex-bridge-service.exe --foreground --data-root C:\path`。portable 目录随附的是
与应用架构匹配的 `WebView2Loader.dll`；Windows 仍必须预先安装系统级 WebView2
Evergreen Runtime，这是 WebView2 native app 的运行前置条件。缺少 Runtime 或 loader
时壳保留任务管理功能并明确显示聊天页不可用。

GitHub Actions（`.github/workflows/windows.yml`）在 windows-latest 上构建 x64 与
ARM64 两套服务/壳产物，在构建与测试后分别上传
`codex-bridge-windows-x64.zip` / `codex-bridge-windows-arm64.zip`。这些 CI artifact
是可解压的 portable 交付包，不是 MSI/MSIX 安装器，不负责服务注册、卸载或自动安装
WebView2 Evergreen Runtime；ARM64 只做交叉编译与链接。

Windows 可通过 `CODEX_BRIDGE_CODEX_EXECUTABLE` 指定 `codex.exe` 或标准 npm
`codex.cmd`；后者不会直接作为子进程启动，而是解析并验证其架构对应的原生
`codex.exe`。未显式配置时依次检查常见用户安装位置与 `PATH`。

macOS 侧命令保持不变：`Scripts/with-xcode.sh xcodebuild …` /
`Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore`。

## 已知限制与语义差异

1. **Secure Tunnel 在 Windows 上不可用**。pinned 的 OpenAI `tunnel-client`
   helper 只有 darwin amd64/arm64 构建，Windows 侧启动一律 fail-closed
   （`TunnelManagerError.launchFailed`）。等上游提供 Windows 构建后，在
   `TunnelProcessLauncher` 的 Windows 分支接入即可。
2. **路径安全遍历的 TOCTOU 差异**。Win32 没有 `openat`，Windows 分支在打开
   前逐组件校验 reparse point（拒绝符号链接/junction 逃逸），但存在理论上的
   检查-打开窗口；隐私主要依赖用户目录 ACL。macOS 分支的相对 fd 遍历语义
   保持逐字节不变。
3. **IPC 并发模型**。XPC 允许同连接并发请求；Windows 命名管道按连接逐请求
   顺序应答（响应 FIFO 匹配），流式推送以 kind-2 帧交织传输。
4. **凭据管理器上限**。CredMan generic blob 上限 2560 字节，超出即拒绝
   （Keychain 上限 16KB）。当前用途（tunnel runtime key、MCP path secret）
   均远小于该值。
5. **数据目录**。Windows 默认 `%LOCALAPPDATA%\CodexBridgeService`；`--data-root`
   接受盘符或 UNC 绝对路径。POSIX 的 0700/属主校验在 Windows 由用户目录 ACL
   承担（校验目录真实存在且非 reparse point）。
6. **GRDB / SQLite**。GRDB 尚未官方声明支持 Windows
   （groue/GRDB.swift#1498），但当前服务持久化已通过 vcpkg sqlite3 构建。
   Windows 与 GRDB 的 Linux 配置一致，定义 `SQLITE_DISABLE_SNAPSHOT`，因为系统
   sqlite3 不提供实验性的 snapshot 符号；本项目未使用该 API，常规事务/WAL/迁移
   不受影响。
7. **DeepSeek Harness 运行时模块链接**。受控 profile 需要把已校验的
   `node_modules` 目录链接到隔离运行目录；Windows 创建目录符号链接可能要求
   Developer Mode 或 `SeCreateSymbolicLinkPrivilege`，失败时保持 fail-closed。
   是否需要改为受控 junction，待 Windows 真机验收后决定。
   Windows 上 Node 解释器必须是有效 PE；由 Node 间接执行的 Harness 脚本入口
   仍按正规文件、句柄身份与摘要校验，不误要求脚本本身是 PE。
8. **Windows UI 尚未完全对齐 macOS**。当前已支持服务状态、任务列表与稳定选择、
   任务元数据、历史/实时对话、Interrupt、支持能力约束下的排队式 Steer、审批中心，
   以及 WebView2 ChatGPT 页面。审批中心支持任务审批与 Direct 审批的读取、详情查看、
   允许/拒绝和过期后刷新；项目/Agent 管理、日志和完整设置页仍待补齐。

## 验证路径与 CI 现状

- macOS：全量 `swift test`（所有套件 0 失败为门禁）+ Xcode Debug 构建。
- Windows：`.github/workflows/windows.yml`（windows-latest）分别构建 x64 与
  `aarch64-unknown-windows-msvc`；Windows 专属源码（`#if os(Windows)`）由 CI
  编译；x64 还运行 Domain、AgentCore、Security、Codex RPC resolver 与跨平台
  AppCore 任务呈现测试，并从 staged portable 目录在隔离 PATH 下启动服务，使用
  独立数据目录完成 SQLite/服务组装并等待本地 MCP ready。
  ARM64 是交叉编译/链接门禁，不能替代 ARM64 真机运行验收。
- Windows 的 `swift test --filter` 仍会编译 manifest 在该平台声明的其他 target；
  因此 SwiftUI 壳与 macOS 测试 fixture 只在 macOS 清单中声明，Windows 再由
  filter 选择已适配的冒烟套件。

### CI 工具链安装（已踩平的坑）

1. `swift-actions/setup-swift` 的版本目录不含 6.x Windows 工具链 → workflow
   直接下载 swift.org 官方安装器静默安装（`/quiet /norestart`）。
2. 安装器默认 **per-user**，位置 `%LOCALAPPDATA%\Programs\Swift`；安装完成后
   用 `Get-ChildItem -Recurse -Filter swift.exe` 定位并把目录写入 `GITHUB_PATH`。
3. Swift 6.1.2 / 6.2.2 **release** 安装器存在缺 DLL 打包缺陷
   （swiftlang/swift#86191，`_CompilerSwiftWarningControl.dll` 未打入），表现为
   `swift.exe` 以 0xC0000135 静默退出；**6.3.3 起已修复**。
4. 工具链的宿主运行库（swiftCore/swiftCRT/swiftDispatch/FoundationEssentials/
   mimalloc）由 bundle 的独立 **Runtime Libraries** MSI 装在
   `Runtimes/<ver>\usr\bin`，必须一并加入 PATH。
5. 安装器同时写入 `SDKROOT`（bundled `Windows.platform` SDK）——MSI 改的机器
   环境变量不会传导到已在运行的 job step，需用 `GITHUB_ENV` 显式转发。
6. GRDB 的 `GRDBSQLite` 是 systemLibrary（`link "sqlite3"`），Windows 无系统
   sqlite → CI 用 vcpkg 安装 sqlite3 并把 vcpkg/MSVC/Windows Kits 的
   include/lib 组合进 `INCLUDE`/`LIB`（注意：设置 `LIB` 会覆盖 MSVC 自动发现，
   必须完整组合；`BOOL` 在 WinSDK Swift 映射里是 `Bool`，不能与 `0` 比较）。
7. Windows Defender 实时扫描会显著拖慢 Swift 编译，workflow 已对构建目录与
   编译进程加排除项。
8. **windows-11-arm runner 的 ARM64 Windows 系统库不可用**：Swift/ARM64
   MSVC 编译器与 vcpkg sqlite 均可用，但链接缺 `kernel32.lib`、
   `runtimeobject.lib`、`ucrt.lib`，`LIB` 中没有 Windows Kits 的 `um\\arm64` /
   `ucrt\\arm64`。因此 ARM64 门禁改在 windows-latest 上使用 ARM64 MSVC/Windows
   Kits 库交叉编译，并在构建前显式预检依赖库；若原生 ARM runner 补齐组件，可再
   恢复原生构建。交叉编译不替代 ARM64 运行验收。
9. 上游 **MCP swift-sdk 0.12.1 不支持 Windows**（对 EventSource 的依赖带
   `.when(platforms:)` 排除 Windows，但源码无条件 `import EventSource`，且
   `URLSession.bytes(for:)` 在 Windows FoundationNetworking 上不存在）→ 已
   vendor 至 `Vendor/swift-sdk` 并打补丁：`canImport(EventSource)` 守卫 +
   `URLSession.bytes`/SSE 兼容 shim（SSE 在 Windows 上为整段缓冲接收，非增量
   流式）。上游恢复 Windows 支持后可切回。
