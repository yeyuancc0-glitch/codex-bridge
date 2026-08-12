# Codex Bridge Project Guide

## 项目长期目标

- 构建一个 GitHub 开源、个人自托管、零开发者云服务器的原生 macOS 应用。
- 让 ChatGPT 网页版通过 MCP 安全调用用户本机 Codex；ChatGPT 负责形成任务契约，Codex 负责执行，Luna 负责只读监督，Bridge 负责权限、状态、审批、连接和证据。
- V1 的完成标准以 `ChatGPT-Codex-Bridge-原生Swift本地开源版完整方案-V2.0.md` 为准；不能把局部原型当作完整交付。

## 权威来源

1. 用户当前明确要求与本文件。
2. `ChatGPT-Codex-Bridge-原生Swift本地开源版完整方案-V2.0.md`：产品与架构基线。
3. `DESIGN.md`：界面、交互、页面状态与设计系统基线。
4. 当前代码、测试和真实运行结果；若文档与代码冲突，先核实，再修正文档。

## 技术栈与运行环境

- Swift 6，严格并发检查；最低 macOS 14。
- SwiftUI 为主，AppKit 补充菜单栏、窗口、目录选择和系统集成。
- Swift Package Manager；发布应用最终需要完整 Xcode、Universal 2、Hardened Runtime、签名与公证。
- Codex 通过本地 `codex app-server` stdio JSON-RPC 连接；Execution 与 Supervisor 使用隔离进程。
- 本地 MCP 只监听 `127.0.0.1`，默认通过官方 Secure MCP Tunnel helper 连接 ChatGPT。
- SQLite 持久化，计划使用 GRDB；日志使用 swift-log；密钥只进入 Keychain。
- Git 与验证命令使用 `Process` 和 argv 数组，不拼接 Shell 字符串。
- 2026-08-12 本机事实：外置完整 Xcode 27.0 Beta 5（build `27A5237l`）位于 `/Volumes/fanch/Applications/Xcode-beta.app`，签名、License、First Launch 与全部 27.0 SDK 检查通过；Codex CLI 为 `0.147.0-alpha.6.5`，Git 2.54.0。
- 系统级 `xcode-select` 仍指向 Command Line Tools，因为切换需要用户管理员密码。项目命令必须通过 `Scripts/with-xcode.sh` 或显式 `DEVELOPER_DIR=/Volumes/fanch/Applications/Xcode-beta.app/Contents/Developer` 运行。

## 开发协作规则

- 先读根目录及待修改目录最近的 `AGENTS.md`；子目录规则优先但不能覆盖全局安全边界。
- 追求简单数据结构和单向依赖；函数嵌套不超过 3 层，避免过度设计、循环依赖和重复状态源。
- Never Break Userspace：协议模型、持久化格式和公开接口的变更必须兼容，或提供明确迁移。
- 不保留死代码、备用旧路径或陈述字面意思的注释。
- 测试验证真实状态和副作用；Mock 仅用于隔离边界，不用“只断言 Mock 被调用”替代行为验证。
- 不读取 `~/.codex/auth.json`、浏览器数据、账号 Token、Key、Cookie、SSH Key 或无关项目文件。
- 不自动 commit、push、merge、stash、reset、删除项目或执行生产迁移。
- 完成一个可独立验证的功能后及时提交 Git；不提交临时计划、测试垃圾、敏感数据或本机生成凭证。
- 复杂任务可使用子代理并行，但子代理不得删除本机文件；共享文件先分配明确所有权。
- UI 与动效只使用 F-design 作为设计技能来源，不调用其他 UI/动效设计技能。

## 架构与状态归属

```text
AppShell -> Presentation -> Application Services -> Domain -> Infrastructure Adapters
```

- `TaskCoordinator` + `EventStore` 是任务事实的唯一来源；ViewModel 只做 `@MainActor` 投影。
- 项目访问唯一来源是 `ProjectRegistry`；MCP 只接受不可猜测的 `project_id` 和相对路径。
- 所有 app-server SDK/Schema 差异封装在 Codex RPC 适配层。
- 所有 MCP SDK 类型封装在 MCP 适配层，不能渗入领域层。
- Execution 与 Supervisor 请求、事件、生命周期和失败恢复完全隔离。
- Supervisor 只读、无网络、`approvalPolicy = never`，不能修改项目或批准风险操作。
- Policy Engine 是安全边界；模型判断只是证据，不能扩大权限。
- 任务事件追加写入，当前状态从事件归约；禁止修改历史事件。
- `TaskPhase` 与 `TaskActivity` 分离：监督/纠偏是 activity，不伪造生命周期变化；恢复使用 `recovering/unknown`，完成必须已有最终报告。
- interrupt/suspend 先记录意图，只有 app-server 的 turn 停止事实才能进入对应终态。
- 任何会改变 Codex 状态的审批、停止或纠偏操作都先追加持久化意图；只有 RPC 成功或 app-server 事件确认后才能记录完成事实。Suspended 不占用 active Thread/工作树锁，resume 必须重新原子获取两把锁并启动新 turn generation。
- `EventStore` 通过事件序号 CAS 追加；提交幂等键是 `(origin, key)`，同指纹复用、异指纹拒绝；Thread 与工作树两把锁必须在同一 SQLite 事务获取。

## 安全不变量

- 本地 MCP 仅回环监听，并使用 Keychain 中的 256-bit 随机认证 Secret；Inspector/本机开发可用秘密路径，Tunnel 生产链路必须用固定 `/mcp` 路径与 fd-backed 静态请求头。
- MCP 不接受任意绝对路径，不提供万能 Shell 工具。
- 相对路径必须标准化、解析符号链接后再次验证仍在注册根目录内；读取时从根目录描述符逐级 `openat + O_NOFOLLOW`，并复核根与目标文件的 device/inode，防止校验后替换竞态。
- 默认拒绝 `.env*`、私钥、Keychain、浏览器 Cookie、Codex auth 等敏感路径。
- Runtime Key 只用于 Tunnel，永不传给 Codex/Luna，永不写日志或支持包。
- 网络默认关闭；包安装、网络、Git 写和项目外访问要求本机确认。
- 高风险删除、系统写、凭证读取、生产迁移直接拒绝。
- 同一 Thread 同时最多一个 Bridge active turn；写任务持有项目工作树锁。
- 幂等键必须阻止重复任务、重复 Thread、重复 turn 和重复审批弹窗。

## 项目结构记忆

- `App/`：应用入口、窗口、菜单栏、资源与 Entitlements。
- `UI/`：Onboarding、Overview、Projects、Threads、Tasks、Approvals、Connections、Logs、Settings 与共享原生组件。
- `Packages/BridgeCore/Sources/BridgeDomain`：值对象、任务状态机、错误和协议。
- `BridgeCodexRPC`：Codex 进程、JSON-RPC、能力协商和版本兼容。
- `BridgePersistence`：SQLite/GRDB 事件存储与迁移。
- `BridgeProjects` / `BridgeGit` / `BridgeSecurity`：项目白名单、Git 证据与确定性策略。
- `BridgeMCP`：本地 Streamable HTTP MCP 与工具适配。
- `BridgeSupervisor`：检查点、结构化判断、防循环与纠偏。
- `BridgeTunnel`：官方 helper 校验、启动、健康和恢复。
- `BridgeReporting`：结构化最终报告和脱敏支持包。
- `Prototypes/AppServerProbe`：阶段 0 可行性验证；稳定后能力进入 `BridgeCodexRPC`。
- `Tests/`：真实集成、安全、UI 和隔离 Fixture；任务结束清理无长期价值的产物。

## 设计与产品原则

- 产品是原生开发者/运维工具，不是营销网站；首要价值是状态清楚、证据可信、审批安全。
- 导航按真实任务分区，不用同质化卡片墙；优先列表、表格、时间线、分栏、分隔线和原生 Inspector。
- 系统字体、SF Symbols、系统浅/深色和系统可访问性设置优先。
- 色彩按语义角色使用；颜色不能单独表达状态，状态同时有文本与图标。
- 动效低能量、可中断，只说明连接、状态、展开和进度连续性；Reduced Motion 下立即切换。
- 不使用通用 AI 紫蓝渐变、玻璃拟态、装饰光球、嵌套卡片或假指标。
- 菜单栏与主窗口共享状态源；菜单栏只提供快速状态和高频控制。
- 窗口紧凑模式重排信息而非简单压缩；核心审批和任务控制始终可达。

## 已确认决策

- 不建设开发者云服务器、账号、计费或多租户后台。
- 不启用 Mac App Sandbox；启用 Hardened Runtime、签名、公证和项目白名单。
- 默认 OpenAI Secure MCP Tunnel；用户自备强认证 HTTPS 为高级替代；本机模式用于开发。
- Codex 官方 ChatGPT 登录负责 Execution 与 Supervisor 用量；不要求模型 API Key。
- 动态读取模型和 reasoning effort；不可用 Luna 时不静默降级。
- `submit_task` 异步返回，任务通过游标查询；ChatGPT 对话不能被本机主动唤醒。
- V1 默认原工作区并保存 Git baseline；新 Thread 可实验性使用 worktree，绝不自动清理。
- 设计交付模式由用户授权代理决定：采用“完成设计包后直接实现”，不生成页面参考图。

## 实施顺序

1. 真实验证 Swift 对当前 Codex app-server 的 initialize、模型、线程、turn、steer、interrupt 和 Supervisor 可行性。
2. 建立原生应用骨架、持久化、日志、Keychain、系统检测和项目注册。
3. 完成本地只读 MCP 闭环，再接 Tunnel。
4. 完成任务执行、安全审批与结构化报告。
5. 完成 Luna Supervisor、恢复、完整 UI、通知、打包与发布。

## 常用命令

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests
Scripts/with-xcode.sh swift run --package-path Packages/BridgeCore codex-rpc-fixture basic
Scripts/with-xcode.sh swift run --package-path Prototypes/AppServerProbe app-server-probe --help
Scripts/verify-mcp-inspector.sh
Scripts/build-tunnel-helper.sh OUTPUT_DIRECTORY
Scripts/verify-tunnel-helper.sh HELPER_DIRECTORY TRUSTED_UNSIGNED_SHA256
Scripts/test-tunnel-helper-config.sh
codex app-server generate-json-schema --out DIR
```

- 完整 App 构建、UI Test、签名和公证命令在建立 Xcode 工程后补充。

## 常见坑与注意事项

- `codex app-server` 是实验接口；只信当前本机 Schema、能力协商与真实回归，不能硬编码记忆中的字段。
- 当前 app-server wire 契约与方案的必要修正记录在 `docs/CODEX_PROTOCOL_COMPATIBILITY.md`；尤其注意无 `jsonrpc` 字段、Thread/Turn 两套 sandbox 表达、开放 reasoning effort 和多种审批响应。
- `turn/start` 响应只表示请求已受理；必须等待匹配的 `turn/started` 事件后才能 steer 或 interrupt，不能把请求响应当作 active-turn 事实。
- stdout 是 JSON-RPC 协议通道；任何非 JSON 污染都必须检测，诊断只读 stderr。
- 进程退出必须原子取消全部等待请求，避免 continuation 泄漏或重复恢复。
- `CodexAppServerClient` 是一次性进程会话；停止、初始化失败或协议失败后由上层创建新实例，不能复用已终止的 dispatcher/event stream。
- app-server stdout 与事件队列都必须有硬上限；审批/服务端请求不得静默丢弃，拥塞时终止会话并进入恢复。
- 每个 app-server 会话只能有一个事件消费 actor；多个 `AsyncStream` iterator 会分流而不是广播，UI/执行器/审批必须订阅该 actor 归一化后的事件。
- Xcode 27 下不要在 detached task 中用阻塞式 `FileHandle.read(upToCount:)` 驱动管道；使用 `readabilityHandler` 接入有界 `AsyncStream`，再由单消费者解析。
- Thread 只能按规范化 cwd/worktree 精确绑定，不能按标题或“最近使用”猜测。
- 自动审批不能信任审批请求里的 shell 字符串或 best-effort `commandActions`；必须用 `threadId + turnId + itemId/approvalId` 关联已持久化的权威执行事件，缺少规范化 argv、路径或大小时一律不自动批准。
- 只读命令自动放行必须使用固定系统可执行文件路径，不能只看 basename 或未解析的 PATH；配置验证命令仍先经过系统硬拒绝与 wrapper 检查。
- dirty 工作区中任务修改与用户修改可能混合；必须保存 baseline 并在报告中诚实标注。
- Git 证据命令只能用固定 `/usr/bin/git`、最小环境和已打开目录 fd 作为 cwd；仓库本地 filter、fsmonitor、include、textconv/command 或任何 `filter` attribute 都必须在执行 status/diff 前 fail-closed，防止证据收集执行项目代码。
- Tunnel 断线不能中断本地任务，但断线期间不得接受新的远程任务。
- `tunnel-client` 必须使用调用方预建的 0700 私有根、dirfd/inode 绑定的每次运行目录、Unix-domain health/admin socket 与最小化子进程环境。禁止把配置交给可替换的 pathname；非秘密配置使用固定 argv，Runtime Key 经 fd3、MCP 静态认证头经 fd4。官方 v0.0.11 不支持把 MCP URL 写成 `file:`，所以只传非秘密 `http://127.0.0.1:<port>/mcp`。`/readyz` 只证明本地 MCP 就绪，只有 health peer PID 匹配、严格 ready 且 control-plane poll 成功并新鲜时才可显示 Tunnel 已连接。
- Tunnel helper 必须先按外部可信的签名后 SHA-256 校验打开的同一 fd，再以 suspended 状态 spawn；只有动态 SecCode 通过宿主 Team requirement 且 CDHash 与静态 fd 身份相同时才恢复和写入秘密。签名前 supply manifest 不能充当运行时信任根。
- Swift MCP SDK 0.12.1 不提供可直接导入的生产 HTTP listener；`BridgeMCP` 必须自建仅绑定 `127.0.0.1` 的 NIO 外层，负责秘密路径或 Tunnel 认证头、请求/会话/结果上限、超时、背压和清理。SDK 的 stateful stored events 与多处 AsyncStream 无界，须按 `docs/MCP_SWIFT_SDK_INTEGRATION.md` 轮换会话。
- `BridgeMCP` 的首批公开面固定为五个只读工具；每个 HTTP session 独占一个 strict SDK Server，全局/单 session 工具并发上限为 8/2，完整双形态结果上限 200 KiB，响应最迟 25 秒关闭并回收 session。新增工具不能绕过这些统一边界。
- 官方 MCP Inspector 验收固定使用 `@modelcontextprotocol/inspector@2.1.0` 和测试专用随机 Path Secret；错误调用必须分别核验 stdout 完整结果、stderr `tool_is_error` 与退出码 5。Inspector 是 one-shot，不能把 fresh connection 称为 same-session reconnect，也不能代替协议取消测试。
- 不带包装脚本的 `/usr/bin/xcodebuild` 会误用 Command Line Tools；看到测试宏、XCTest 或 SDK 缺失时先检查 `DEVELOPER_DIR`，不要重复安装 Xcode。

## 维护检查

- 每次任务结束前检查是否出现新的长期命令、架构决策、兼容坑或过时事实。
- 仅把长期有效且不敏感的信息写入本文件；一次性进度放到 issue/提交记录或阶段台账。
- 超过 250 行时整理、核对并压缩。
