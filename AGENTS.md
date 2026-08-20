# Codex Bridge Project Guide

## 产品目标

Codex Bridge 是一个个人自托管、零开发者云服务器的本机桥接工具：

```text
ChatGPT Web → Secure MCP Tunnel → CodexBridgeService → 本机 Codex Execution
                                                   └→ 独立 Supervisor
CodexBridge.app → 本机 XPC → CodexBridgeService
```

V1 的用户结果是：ChatGPT 网页版可以读取用户明确注册的本地项目和项目绑定的 Codex Thread，把任务交给本机 Codex，并在任务开始时启动独立 Supervisor。原生 macOS App 只负责配置、状态展示和本机审批；关闭或退出 App 不得停止后台 Service 或活动任务。

## 权威来源

按以下顺序判断：

1. 用户当前明确要求。
2. 本文件。
3. `docs/V1_LIGHTWEIGHT_REFACTOR_PLAN.md` 中仍与代码一致的架构和验收原则。
4. `DESIGN.md` 中仍适用的原生 UI 原则。
5. 当前代码、测试和真实运行结果。

历史方案与旧阶段台账只作背景参考：

- `ChatGPT-Codex-Bridge-原生Swift本地开源版完整方案-V2.0.md`
- `docs/PHASE_LEDGER.md`
- `docs/FOLLOW_UP_PLAN.md`

文档与代码冲突时，以代码和真实测试为准，并修正文档。跨窗口继续开发时还应读取最新的 `docs/HANDOFF_*.md`，但交接文件不替代本文件中的长期规则。

## 当前实际架构状态

- `BridgeServiceCore` 已提供单 SQLite 数据库、项目、设置、直接任务状态、展示型事件和项目级活动写任务约束。
- 任务对话消息已进入 Service SQLite（`bridge_service_task_messages`，V4 schema）：每条消息按 `(task_id, message_key)` 去重，随任务级联删除；消息带 `kind`（`user`/`agent`/`reasoning`/`tool_call`）及 `tool_name`/`tool_status`/`tool_arguments` 列，用户消息、Codex agent 文本、reasoning 思考链与工具调用增量在 `TaskConversationBuffer` 中按 key 归并，最终以权威全文落库。
- `BridgeCodexService` 已提供独立 ExecutionManager、SupervisorManager、本机 Codex 审批、ServiceExecutionCoordinator 和对话订阅推送（`item/agentMessage/delta`、`item/reasoning/textDelta`、`item/mcpToolCall/progress` 流式入 buffer，tool call 经 `item/started`/`item/completed` 更新状态，`turn/completed` 归并权威文本）。
- `BridgeMCP` 已接入轻量 Service API，支持只读与完整动作两种 MCP 暴露模式。工具语义明确区分默认 Codex 路径（`submit_task`/`steer_task`/`interrupt_task`）与显式 Direct 路径（`direct_write_project_file`/`direct_edit_project_file`/`direct_apply_project_patch`/`direct_manage_project_path`/`direct_exec_project_command`/`direct_read_command`/`direct_write_stdin`/`direct_interrupt_command`）；Direct 工具仅当用户明确要求 ChatGPT 直接执行时使用。
- `BridgeSkills` 提供只读 Skill 目录能力与 Action 执行：SKILL.md 用真实 YAML Frontmatter 解析（`SkillFrontmatter`，支持含段落空行的 `>`/`|` block scalar、block sequence、嵌套 map、inline 数组与引号）；Skill 以 Action 契约暴露，优先读显式 `actions:` 元数据，兼容自动发现只暴露 SKILL.md 明确引用的 `scripts/` 顶层脚本，不能仅凭扩展名或 shebang 把内部库当入口；无脚本/Action 的 `agent-reach` 通过 Bridge 内置只读 Action adapter 暴露固定 `doctor` 与各平台查询前缀，不开放安装、配置或任意 shell；Action 网络要求为 `denied`/`required`/`unspecified` 三态，只有显式 `denied` 才进入 `sandbox-exec (deny network*)`，`unspecified` 保守地按可能联网走项目权限与本机审批；`run_skill_action` 复用 Direct Command 会话，解释器解析为绝对路径，调用方不能覆盖网络声明。
- `BridgeDirectCommand` 提供完整 Direct Process Session：每项目单活跃会话、命令策略（`denied`/`safe`/`full`，safe 内置命令使用参数级 capability validator，项目根内脚本和用户允许命令仍按显式规则授权，未声明网络能力默认进入 deny-network sandbox）、结构化 argv 精确/前缀匹配、`posix_spawn` 原子创建进程组、有界超时/stdin/head-tail 输出、带进程启动身份的孤儿清理，以及完成会话 TTL/LRU；`list_project_commands` 分别返回实际生效的 `built_in_commands` 与 `registered_commands`，并保留旧 `commands` 字段兼容；Direct 会话与 Codex 写任务共用 token 化 workspace gate 互斥。
- `DirectGitRunner` + `serviceDirectGitCommit` 提供受控 Git 提交（`direct_git_commit`）：只允许显式文件或全部变更的本地提交，使用临时 index 隔离提交边界、提交成功后仅同步已提交路径到真实 index，并在暂存和提交前执行敏感路径与凭证检测；禁止 amend/reset/改写历史与 push，复用 workspace gate 与本机审批。
- `DirectActionApprovalCenter` 提供 Direct 本机审批：pending approvals 经 XPC 推送到 App 展示，approve/deny 由本机用户决定；approval 绑定规范化 sorted-key JSON payload digest + `client_request_id` 一次性消费，pending 与 approved grant 均会过期，deny 在冷却期内阻止等价请求重复弹窗，Service 重启后全部失效不可重放；`direct.approval_mode` 可由用户显式切换 `auto`/`require`。
- `CodexBridgeService` 已作为 bundled LaunchAgent 后台进程运行，并通过版本化 XPC 向 App 提供本机操作接口；V1 的 XPC 信任边界明确为同 UID、同用户 LaunchAgent 会话，而非只允许官方 App 签名；XPC 增加任务删除、对话分页与对话流式订阅（`CodexBridgeTaskStreamListener` 推送），App 端 `TaskConversationModel` + `TaskConversationSheet` 实时渲染打字机式对话，包含可折叠思考链区块与工具调用卡片。
- App 的 2 秒后台轮询只刷新轻量 Service/任务/审批状态；Codex Thread Catalog 在连接、手动刷新、项目切换、任务生命周期变化或 60 秒低频兜底到期时读取，启动后不再自动读取首个 Thread 全文。
- 原生 App 的 Thread 列表与读取只接受 Service SQLite 中 `source == chatgpt.mcp` 且已绑定 `codex_thread_id` 的任务；同项目中由 Codex App/CLI 手动创建的 Thread 不进入 App。当前最近 500 条任务是有意的有界 UI 策略，不承诺 App 展示全部历史；MCP 的 `list_threads`/`read_thread` 保持原有同项目查询语义。
- App 的 Codex 活动反馈以 Service 任务状态为生命周期边界，并用未完成的 reasoning、tool call 与 agent 消息区分“思考”“执行工具”“输出”；任务进入终态前不得因暂时没有文本增量而提前停止活动提示，减少动态效果模式使用静态光球。
- 项目页 Skill 区域默认只显示 4 个紧凑预览并提供总数、剩余数和“查看全部/收起”，不能让完整 Skill 清单挤压权限、命令与 Thread 内容；Thread 行必须保留可发现的会话删除入口，只有终态任务可删除且必须二次确认。
- 工作台内嵌 `WKWebView` 离开工作台后保留 3 分钟复用窗口，期间返回取消休眠；持续离开后释放 WebView，但继续使用默认持久化 `WKWebsiteDataStore` 保留网站登录数据。
- 工作台内嵌浏览器继续拒绝会交给 LaunchServices 的外部 Scheme；用户触发的 HTTP(S) 及 `blob:`/`data:` 下载必须走 `WKDownload` 并显示本机保存面板，响应侧同时识别不可展示 MIME 与 `Content-Disposition: attachment`，不能把下载和登录防外跳混为同一拦截规则。
- App 对话流在 `TaskConversationModel` 侧按约 40 ms 合并 push 后一次发布 UI 状态，工作台历史与实时消息使用 `LazyVStack`，避免逐 token 触发完整 SwiftUI 刷新。
- 正式 App Target 已使用 `BridgeServiceAppShell`，不再启动旧 App 内控制平面。退出 UI 只断开 XPC，不注销 Service，不停止任务。
- Secure MCP Tunnel 已由后台 Service 持有。Tunnel ID 与 enabled 状态进入 Service SQLite；Runtime Key 与本地 MCP Header Secret只进入 Keychain。
- Tunnel helper 当前固定为 OpenAI `tunnel-client` v0.0.10、commit `105e17a79a36e4e5c897fd698ed2b8dbf935b144`，并有固定归档哈希、Universal 2 构建和官方 arm64 `doctor` 兼容门。
- `BridgeLegacyImport` 已完成旧项目与旧 Tunnel ID 的一次性只读迁移，并已在生产 Service 组合根启动阶段接线；迁移失败只记录固定降级状态且不阻塞 Service，测试和自定义组合默认仍通过 `nil` 禁用真实旧目录读取。
- `BridgeCoordinator`、`BridgePipeline`、旧 EventStore、Evidence、Verification、Reporting、Retention 和备份恢复仍在仓库并继续参与历史测试，但不再是正式 App 的运行路径。真实 ChatGPT 闭环和迁移验收前不得删除。
- `productionReviewAvailable` 及其他历史发布门不得通过改常量伪装完成。
- 迁移期间禁止旧数据库与新数据库长期双写。

## 技术栈与环境

- Swift 6，严格并发检查，最低 macOS 14。
- SwiftUI 为主，AppKit 用于系统集成。
- Swift Package Manager 与 Xcode 工程。
- Codex 通过本机 `codex app-server` stdio 协议连接。
- MCP 使用官方 Swift SDK，并由 NIO 提供受限 HTTP 外层。
- SQLite 使用 GRDB。
- 密钥只进入 Keychain；Bridge 不读取或复制 Codex `auth.json`。
- 本机 Xcode 位于 `/Volumes/fanch/Applications/Xcode-beta.app`。项目命令必须通过 `Scripts/with-xcode.sh`，或设置 `CODEX_BRIDGE_XCODE_DEVELOPER_DIR`。

## 模块与依赖方向

保持单向依赖：

```text
CodexBridge.app → BridgeServiceAppShell → BridgeIPC → CodexBridgeService
CodexBridgeService → BridgeServiceHost
BridgeServiceHost → BridgeServiceCore / BridgeServiceApplication / BridgeMCP
                  → BridgeCodexService / BridgeTunnel / BridgeSecurity
BridgeCodexService → BridgeCodexRPC
BridgeDirectCommand → BridgeServiceCore / BridgeProjects / BridgeSecurity
BridgeMCP → Service API
BridgeLegacyImport → BridgeServiceCore + 旧项目模型读取边界
```

主要模块职责：

- `BridgeServiceCore`：新单库项目、设置、任务和展示事件。
- `BridgeCodexRPC`：Codex app-server 进程与协议适配，不重写。
- `BridgeCodexService`：Execution、Supervisor、本机审批和协调。
- `BridgeServiceApplication`：MCP/XPC 共用的轻量应用服务。
- `BridgeMCP`：远程工具边界。
- `BridgeIPC`：版本化、有界的 XPC DTO 和 Client。
- `BridgeServiceHost`：后台 Service 组合根、XPC、MCP、Tunnel 与生命周期。
- `BridgeServiceAppShell`：纯 UI、本机项目管理、状态和审批。
- `BridgeDirectCommand`：Direct Process Session、命令策略、输出边界和孤儿清理。
- `BridgeLegacyImport`：一次性只读旧配置迁移，不承担长期双写。
- `BridgeSecurity`、`BridgeFiles`、`BridgeProjects`：继续复用的安全边界。

`BridgeServiceApplication` 的查询、任务、Direct 文件、Direct 命令和审批实现可按同一 actor 的 extension 拆分，但状态仍只由该 actor 持有；Host 关闭 Direct 会话与审批时应调用 Application 的 package 内生命周期门面，不能重新直接编排其内部组件。

禁止 UI 持有 Codex、MCP、Tunnel 或 Supervisor 生命周期。禁止新架构重新依赖旧 Coordinator/Pipeline，也禁止把 MCP DTO 变成领域状态来源。

## V1 安全边界

- MCP 只接受不透明项目 ID 和相对路径。
- 项目根必须由用户选择并捕获规范路径、device、inode。
- 文件读取必须拒绝绝对路径、符号链接逃逸、`.env*`、私钥、浏览器数据和 Codex 认证文件；V1 没有 read approval 流程，因此 App 与 XPC 都不允许把 read 配置成 `requiresLocalApproval`，只能选择 allowed 或 denied。
- MCP、XPC、Codex、Supervisor、迁移文件、文本、数组、事件队列、进程输出、请求和响应都有硬上限。
- ChatGPT、Supervisor 和 Bridge 都不能批准 Codex 操作；只有本机用户能允许或拒绝。权限优先级固定为项目硬策略 > 单任务请求 > 全局 access mode，后两者都不能越过项目或任务明确拒绝的写入、网络与读取边界。
- 未识别的审批类型一律拒绝。
- 同一项目最多一个活动 workspace-write 任务；read-only 任务可并行。
- Supervisor 失败只降低监督状态，不能终止 Execution。
- `submit_task` 提交后立即启动，不存在任务级本机批准；只有执行中的危险操作进入本机审批。Service 崩溃后，已开始执行的任务诚实进入 `unknown`，尚未 begin 的短暂 `awaiting_local_approval` 兼容状态进入 `interrupted` 并释放写槽，不得启动新 Turn 冒充旧 Turn 恢复。
- Tunnel 断线只阻止新的远程提交，不取消已经运行的本地任务。
- Direct 命令按结构化 argv 精确/前缀匹配，不拼 shell：`denied` 禁止一切命令；`safe` 的内置 `ls/find/grep/rg` 必须逐参数验证项目根 containment 并拒绝执行器、删除和预处理选项，项目根内脚本与用户「允许命令」规则按显式契约放行，注册命令的 working directory 是授权的一部分且调用方不能覆盖；`full` 放行所有命令但仍受项目网络/写入权限与审批约束，且黑名单同样生效。cwd 与项目内 executable 均在解析符号链接后验证 containment；裸可执行名在固定可信 PATH 中解析为绝对路径后再交给 Process。
- Direct 错误细分到可重试码：`process_launch_failed`（进程启动失败）、`command_denied`（策略拒绝）、`approval_required`、`project_busy`（workspace gate 占用）、`command_timeout`、`git_operation_failed`；合法但不存在的路径返回 `path_not_found`，越权/逃逸才返回 `path_denied`；Direct Write/Edit 输入只用密钥模式检测凭证，源码中的绝对路径不误伤，真实凭证材料返回结构化 `unsafe_content_detected`；`direct_edit_project_file`/`direct_apply_project_patch` 的 SHA 冲突返回 `revision_conflict` 并携带 `current_sha256`、`changed_since_revision` 与有界当前内容摘录；patch 文本校验只走密钥模式（`*** Add File:`/`*** Update File:` 中的 `file:` 标记不会被路径启发式误伤，路径仍由 ProjectPatchParser + sensitivePolicy 把关）；`working_directory` 的 `nil`/`""`/`"."` 统一为项目根，`./X` 归一为 `X`，非法值返回结构化 `path_denied` 而非泄漏异常；`read_project_file` 的 `line_count` 与 schema 统一为上限 10000 行、单响应 200 KiB，超限自动收窄并返回 `next_start_line`，不报错；文件末尾换行是终止符而非幻影空行，不触发多余分页。
- 命名空间变更已发生但目录 fsync 失败时返回 `durability_uncertain`，调用方必须先重读路径而非盲目重试。
- Direct 命令与 Git 子进程都在创建时原子进入独立进程组，有界超时/stdin/输出；中断、Service 关闭和超时执行 TERM→宽限→KILL→wait，Service 崩溃孤儿清理只有在 PID、启动时间和进程组身份仍匹配时才终止进程组。
- Direct 会话常驻后台 Service，退出 App 不停止运行中的本地命令；Direct 审批在内存中一次性消费、可过期、重启失效。
- 不读取、记录、导出或回传 Key、Token、Cookie、登录 URL、验证码、Runtime Key、本地 MCP Header Secret 或认证文件。
- 旧配置迁移只能读取私有、当前用户所有、非符号链接的源目录和文件；迁移失败不得修改旧源或留下半迁移新数据。

## 旧配置迁移长期决策

- 旧源默认位于 `~/Library/Application Support/CodexBridge/`。
- 新 Service 数据位于 `~/Library/Application Support/CodexBridgeService/`。
- 只迁移项目配置、项目权限和旧 Secure Tunnel ID。
- Runtime Key、Codex 登录、旧任务、事件、报告、Evidence、Verification、Supervisor Ledger、Patch、Retention、备份和通知状态不迁移。
- Tunnel ID 可迁移，但迁移后的 Tunnel 必须默认关闭，Runtime Key 必须由用户重新提供。
- 旧 worktree 和不同 repository root 只保留主项目根，并在迁移报告中记录收窄事实。
- 离线外置硬盘项目仍保留已存储的路径、device 和 inode；实际使用时继续执行当前根身份校验。
- 新 Service 中已存在的同键设置不被旧数据覆盖。
- 相同项目 ID 与相同根视为已存在；项目 ID 或根发生冲突时整批迁移回滚。
- 项目、设置和迁移完成标记必须在同一个 SQLite 事务中提交。
- 没有旧数据源时不写永久完成标记，以便后续重试。
- 测试和自定义 ServiceComposition 默认不得读取真实用户旧目录；生产入口必须显式选择旧源。

## 工程规则

- 优先解决真实产品闭环，不为假想风险新增控制平面。
- 不新增 Saga、Ledger、Evidence Store、Capability Store 或第二个 Service 数据库。
- 当前任务状态直接存储；`task_events` 只用于展示和诊断，不参与事件归约。
- 任务对话以 `(task_id, message_key)` 幂等落库；同一项目写任务完成后才允许删除任务记录（`deleteTask`），活动任务删除一律拒绝；删除走 FK 级联清事件与消息。
- 对话增量推送采用确定合并协议：按 `message_key` 归并，`fullContent` 权威替换，`delta` 仅在 `baseContentLength` 与当前内容匹配时追加；客户端订阅先应用原子快照页再消费增量流，订阅与分页在同一 actor 内完成，避免竞态。
- `TaskConversationBuffer` 是对话流的唯一拥有者：用户消息即时 fullContent 通知，agent 文本与 reasoning 增量按 key 累积，tool call 按 `tool:<itemID>` 更新状态与追加进度，`turn/completed` 以权威全文 finalize，close/purge 只由 Coordinator 在任务终态触发；flush 只写 dirty revision，写入失败必须保留 dirty state 并阻止静默 close，成功落库且 final 的历史消息才从活动内存淘汰，单任务常驻最近 64 条窗口，完整历史继续以 SQLite 为权威来源。
- XPC 流式推送按连接持有：Listener 为每个连接建独立 Controller 与 `StreamRegistry`（forwarder 任务 + subscriptionID），连接失效即取消 forwarder 并退订；客户端 `CodexBridgeTaskStreamHub` 是锁保护的注册表，不用 actor，避免区域隔离编译错误。
- 使用数据库约束消除并发特例，避免多个模块复制锁状态。
- 函数嵌套不超过 3 层；一个状态只有一个拥有者。
- 新文件接近 600 行时评估拆分，不重现千行组合文件。
- 不保留死代码、废弃路径、重复实现或陈述字面意思的注释。
- 优先简单、优雅、可维护的方案，不连续堆补丁。
- Never Break Userspace：迁移必须可回退，不能破坏当前稳定提交和现有数据。
- 不引入 Node/TypeScript 产品运行时；继续复用 Swift Codex RPC。
- 不执行大规模破坏性操作，不读取无关目录或敏感信息。

## 测试要求

- 测试真实状态和副作用，不以“Mock 被调用”代替业务验证。
- 数据库测试使用真实 SQLite 文件或内存库。
- 并发测试覆盖跨连接竞争，而不只覆盖单 actor 顺序调用。
- 必须验证同项目写任务互斥、不同项目并行、只读并行、任务与事件同事务、幂等冲突、重启 unknown 和无伪恢复。
- 对话验证消息按 key 幂等去重、分页顺序、删除级联、订阅快照原子性、delta 合并协议、容量上限与 close/purge 后停止推送。
- Execution 使用 fake app-server 真实进程验证 Thread、Turn、steer、interrupt、审批、进程回收、`item/agentMessage/delta` 流式入 buffer，以及 `item/reasoning/textDelta` 与 tool call 生命周期（started/progress/completed）端到端推送。
- Service 验证 App 退出后 Service 与任务继续、Service 崩溃不留孤儿进程，以及 XPC 真实订阅推送到达客户端。
- Tunnel 验证 helper 身份、FD 密钥传递、回环健康端口所有权、严格 readiness、重连和密钥不外泄。
- 迁移验证旧文件不变、事务回滚、重复执行、冲突、不安全源、离线项目和无源重试。
- Inspector 通过不能替代真实 ChatGPT Developer Mode 验收。
- `ProductionArchitectureBoundaryTests` 必须持续验证正式 Service/App 依赖闭包不直接 import 旧 Coordinator、Pipeline、Persistence、Runtime 或旧 AppShell 控制平面；新增生产 target 时同步更新守卫列表。

常用命令：

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --filter BridgeLegacyImportTests
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore --filter BridgeServiceHostTests
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests App
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
Scripts/verify-mcp-inspector.sh
Scripts/test-tunnel-helper-config.sh
```

## Git 与操作边界

- 不自动 push、merge、reset、stash 或删除用户文件。
- 不使用 `git reset --hard`、`git clean` 或其他会抹掉工作区的命令。
- 开始修改前先检查 `git status` 和相关 diff，保留用户已有改动。
- 完成一个独立、可运行、已验证的功能后可以提交 Git。
- 不提交未完成或无法构建的代码、凭证、测试垃圾、临时计划或交接记录。
- `AGENTS.md` 作为长期记忆默认不随功能提交，除非用户明确要求。
- 删除旧模块前创建可回退 tag，并按依赖组逐组删除、逐组验证。

## 用户必须参与的外部边界

- macOS 后台项目首次批准。
- 官方 Codex / Supervisor 浏览器登录。
- OpenAI Tunnel ID 与受限 Runtime Key 输入。
- ChatGPT Developer Mode 添加 MCP、扫描工具和真实对话验收。
- Apple Developer Team、Developer ID、Notary 身份和正式签名授权。

这些凭证和授权不得写入项目记忆、交接文件、日志、测试或 Git。

## 常见坑

- `codex app-server` 是实验接口，只信当前 schema 和真实 fixture。
- Codex 本地安装的 Skill 目录名与 `name` 可能包含空格；Bridge 发现层只要求名称有界、无首尾空白且不含控制字符，不能在读取 `SKILL.md` 前套用命令标识符正则而漏掉合法安装。
- 一个 app-server 事件流只能有一个消费方；需要广播时由上层 actor 分发。
- `turn/start` 响应不等于 active turn，必须等待匹配的 `turn/started`。
- Thread 只能按精确 cwd 绑定项目，不能按标题或最近记录猜测。
- `CODE_SIGNING_ALLOWED=NO` 构建不能用于真实 Secure Tunnel。
- ChatGPT 不能访问 localhost，真实使用仍需要 Secure MCP Tunnel 或用户控制的远程 HTTPS MCP。
- ChatGPT 工作区可能限制 Full MCP 动作工具；不能把动作工具伪装成只读工具绕过平台策略。
- ChatGPT Web 可能缓存当前 MCP 会话的工具 Schema；Service 升级改变工具参数或输出契约后，旧会话可能仍使用旧 Schema，需重新发现工具或重连 MCP。进程内工具目录是静态的，不能用 `listChanged` 伪装成 Bridge 能控制客户端缓存刷新。
- SwiftPM target 必须显式声明源码直接 `import` 的内部模块，不能依赖传递依赖恰好让当前构建通过；删除依赖前同样要核对该 target 的全部源码 import。
- Direct 搜索命令中会读取文件的 value option（例如 `grep`/`rg` 的 `-f`/`--file`）必须同时校验分离参数与 `--option=path` 内联形式的项目根 containment，不能只验证下一个 argv。
- Supervisor 持久 Profile 是个人受信任运行模式，不得宣传为已证明的凭证隔离。
- `ServiceCompositionConfiguration.legacyDataRootURL == nil` 应表示禁用旧数据读取，避免测试误读真实用户目录。
- 旧 SQLite 迁移必须通过已验证文件描述符读取，并拒绝 `journal`、`WAL`、`SHM` 旁路文件；不能先验证路径再让 GRDB 按原路径重新打开。 威胁模型接受同 UID 进程边界：fd-backed 校验减小但不能完全消除“校验后到重新打开之间”的路径替换窗口。
- 旧模块仍通过历史测试不代表它们仍属于正式产品运行路径。
- 系统卷剩余空间不足时 `swift test`/`xcodebuild` 会在 `mkdtemp(/private/var/folders/...)` 报 `No space left on device`；可把 `~/Library/Developer/Xcode/DerivedData` 移到 `/Volumes/fanch`（或清理 `~/Library/Caches/org.swift.swiftpm`）恢复构建。
- macOS `SMAppService` 依赖 Team ID 签名，在未签名或 Ad-hoc 构建下返回 `.notFound`；`SystemBridgeServiceRegistration` 已支持自动降级至用户级 `~/Library/LaunchAgents/org.codexbridge.service.plist` 与 `launchctl bootstrap` 保证本地开发可用。
- LaunchAgent 运行环境下系统 `PATH` 仅包含基础系统目录，`AppServerProcess` 已内置对官方 `/Applications/ChatGPT.app/Contents/Resources/codex` 及常见包管理器路径的自动探测，确保服务能正确调用 `codex app-server`。
- Secure Tunnel Helper 签名校验已支持在 Ad-hoc / 本地开发环境下自动适应无 Apple Team ID 签名，结合严格的 Universal 2 官方 SHA256 摘要进行完整性保护。
- Tunnel helper 的签名后 SHA256 清单必须放在 `Contents/Resources/TunnelClient/`，不能与可执行文件同放 `Contents/Helpers/`；否则 macOS 外层 bundle 签名会把清单误判为未签名嵌套代码，或深度重签 helper 后造成运行时摘要不匹配。
- OpenAI 官方 `tunnel-client` 在启动时会探测 `/.well-known/oauth-protected-resource/mcp`。本地 MCP Server 必须返回保护资源元数据（`authorization_servers: []`）以使 `tunnel-client` 就绪检查通过；在 Swift NIO 中处理该请求时必须在 `receiveEnd` 阶段统一应答，避免在 `receiveHead` 中过早应答引发 NIO `HTTPServerPipelineHandler` 重复写断言崩溃。
- OpenAI 官方 `tunnel-client` 包含 Harpoon 自动注册组件，对于本地 loopback `http://` 目标必须传入 `--harpoon.allow-plaintext-http=true` 避免 Harpoon 报错拦截长轮询通道；启动阶段当 Prometheus `commands_poll_last_successful_timestamp_seconds` 为 0 时，应以 `/readyz` 200 OK 作为基础就绪信号。
- 经由 OpenAI 隧道接收 ChatGPT Web 端的 MCP 探测时，`MCPSessionRegistry` 的 `OriginValidator` 必须允许 `https://chatgpt.com`、`https://chat.openai.com` 与 `https://platform.openai.com`，`AcceptHeaderValidator` 使用 `mode: .jsonOnly` 以兼顾标准客户端请求头；`MCPServiceServerFactory` 使用 `.default` 配置确保平滑握手。
- 本地或 Debug 构建下打包 Helper 时，`stage-tunnel-helper.sh` 需自动回退至 Ad-hoc 签名（`codesign -s -`），使 Mach-O 具备合法的代码签名结构，防止 `SecStaticCodeCheckValidity` 报错 `signatureInvalid`；`MCPSessionRegistry` 对空 Body 的健康探测请求应直接返回 200 OK，避免客户端启动探测时收到 400 Bad Request。

## 维护检查

每次任务结束前检查：

1. 是否产生新的长期架构决策、真实命令、兼容约束或坑点；
2. 本文件中的实际状态是否已经过时；
3. 是否无意扩大 V1 范围或重新引入旧控制平面；
4. 是否能从最近稳定提交安全回退；
5. 是否存在未提交、未验证或可能包含凭证的文件。
