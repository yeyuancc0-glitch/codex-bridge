# Codex Bridge v0.4.0

本公告只记录相对上一版公开版本 v0.3.0 的用户可见变化。

## 本次更新

- 新增 DeepSeek Harness Provider：支持登记固定兼容版本及外部 Profile，动态模型目录、模型与 effort、Read Only/Write、Web/工具/子代理工作流、任务控制、执行证据和本机审批。
- 新增 Antigravity Provider：通过 `agy` CLI 的 stream-json 协议运行，支持 Plan/Accept Edits、原生 sandbox、模型与 effort、Conversation 续接、网络授权和排队继续。
- 统一 Codex、OpenCode、DeepSeek Harness 与 Antigravity 的工作台体验：共用默认项目、Read Only/Write 选择、任务审批、对话时间线、状态查询与 Provider 独立默认设置。
- 新增远程 Agent 启动自动批准开关，默认关闭；新增“退出 App 后保持后台服务运行”设置，默认开启。两项策略分别持久化，不会互相隐式授权。
- 改进 OpenCode 与外部 Provider 的原生能力接入、模型刷新、权限回传、网络任务、会话继续、排队继续、终态判断和故障诊断。
- 修复并发提交、任务终态可见性、结果完成语义、Provider 安装持久化、执行期权限请求、嵌入浏览器刷新，以及工作台会话切换、滚动和 Markdown 展示问题。
- 新增完整使用指南、DeepSeek Harness 中英文接入指南，并重写 README 与 Provider 配置说明。

## Provider 边界

- Codex 仍是默认 Provider，Supervisor 当前仍只支持 Codex。
- OpenCode、DeepSeek Harness 与 Antigravity 都是用户自行安装或构建并明确登记的外部运行时，不随 App 打包，也不由 Bridge 保存其账号凭据。
- DeepSeek Harness 当前每个任务创建新 Session，不支持历史 Session 续接；OpenCode 与 Antigravity 的继续能力必须匹配先前终态任务、同一项目和同一安装实例。
- 外部 Provider 的网络、文件和工具执行使用各自原生策略；Bridge 负责项目准入、明确网络意图、任务启动审批与 Provider permission 回传，不宣称逐包网络隔离。

## 下载文件

- `CodexBridge-0.4.0-macos-arm64.dmg` / `.zip`：Apple Silicon
- `CodexBridge-0.4.0-macos-x86_64.dmg` / `.zip`：Intel Mac
- `SBOM.spdx.json`
- `SHA256SUMS`

从 v0.4.0 开始，macOS Release 不再使用一个 Universal 2 下载包；两个架构分别打包，每个 App、后台 Service 与 Tunnel Helper 都只包含对应架构。

本版仍未配置 Apple Developer ID 证书，也未公证。首次打开时请在 Finder 中右键 App 选择“打开”，或在“系统设置 → 隐私与安全性”中选择“仍要打开”。

公开源码不包含测试目录、测试夹具、UI 自动化、原型、内部架构计划、审查稿、交接文件、个人配置或凭据。
