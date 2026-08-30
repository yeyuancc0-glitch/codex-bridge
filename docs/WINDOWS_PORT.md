# Windows 移植说明（WINDOWS_PORT.md）

Codex Bridge 的核心逻辑（代理引擎、MCP 网关、服务编排、IPC 协议、存储）自
win 分支起与 macOS 解耦，可在 Windows x64 与 ARM64 上构建运行。本文记录
平台层的边界、Windows 侧实现与已知限制。

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
| 桌面 UI | SwiftUI/AppKit（`BridgeServiceAppShell`） | `BridgeServiceAppCore`（跨平台模型层） | Win32 消息循环 + 子控件（`BridgeWindowsShell`） |
| 后台服务注册 | `SMAppService` LaunchAgent | —（Windows 为按需拉起） | 壳启动时探测管道，不存在则拉起同目录 `codex-bridge-service.exe` |
| 文件安全边界 | openat + O_NOFOLLOW 相对 fd 遍历 | `SecureFileReader` / `SecureProjectFileWriter` / `SecureProjectDirectoryMutation` | 逐组件 reparse-point 校验 + CreateFileW（CREATE_NEW / 暂存替换 / MoveFileExW） |
| 代码签名校验 | SecCode（SecStaticCode/SecCode） | `TunnelCodeSignatureVerifier` | 不可用（见下节 Tunnel 限制） |
| SHA-256 | swift-crypto（macOS 上转发 CryptoKit） | `import Crypto` | swift-crypto（BoringSSL 后端） |

## 构建

Windows 需要 Swift 6.1 工具链（swift.org 官方支持 x86_64 与 aarch64）：

```powershell
powershell -File Scripts\build-windows.ps1            # 构建服务 + 壳
powershell -File Scripts\build-windows.ps1 -Test      # 附带冒烟测试
```

产物：`codex-bridge-service.exe` 与 `codex-bridge-windows-app.exe`。运行壳时若
服务未启动会自动拉起；也可手动 `codex-bridge-service.exe --foreground --data-root C:\path`。

GitHub Actions（`.github/workflows/windows.yml`）在 windows-latest（x64）与
windows-11-arm（ARM64）上构建两个产物并运行平台无关测试子集。

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
6. **GRDB / swift-nio / MCP swift-sdk**：GRDB 官方支持 Apple 平台与 Linux，
   Windows 支持未官方声明（groue/GRDB.swift#1498）；NIO 与 swift-crypto 已官方
   支持 Windows。若 GRDB 在 Windows 构建受阻，需要为 `BridgeServiceCore` 引入
   持久化后端抽象——这是 Windows 构建链路上最大的未验证风险点。

## 验证路径

- macOS：全量 `swift test`（所有套件 0 失败为门禁）+ Xcode Debug 构建。
- Windows：`Scripts/build-windows.ps1 -Test` 或 CI workflow。Windows 专属源码
  （`#if os(Windows)`）在 macOS 上不参与编译，编译正确性由 Windows 侧构建与
  CI 验证。
