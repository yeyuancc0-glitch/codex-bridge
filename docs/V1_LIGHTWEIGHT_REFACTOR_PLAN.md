# Codex Bridge V1 轻量化重构实施计划

> 文档状态：待实施基线  
> 创建日期：2026-08-17  
> 代码基线：`main` / `750cc01`  
> 适用范围：从当前“本地 Agent 控制平面”重构为“ChatGPT MCP → 本机 Codex 执行 + 独立 Supervisor 监督”的个人本地工具  
> 说明：本文只定义改动顺序、边界、验收与回滚，不授权在同一轮中直接删除旧实现，也不替代逐阶段测试。

---

## 1. 重构结论

当前项目已经具备较完整的 Codex app-server、MCP、项目文件安全边界、Tunnel、任务状态、Supervisor 和原生 UI 能力，但产品组合方式偏离了实际目标：

- ChatGPT 的任务提交被静态 Supervisor 门禁关闭；
- Supervisor 不是与 Execution 同时启动的独立监督单元，而是同步插入任务事件处理链；
- Supervisor 故障会连带中止主任务；
- Codex 审批当前只能拒绝，无法由本机用户允许；
- App 进程拥有 MCP、Tunnel、Execution、Supervisor 和任务生命周期，退出 App 会停止全部后台能力；
- 事件溯源、证据流水线、Finalization Saga、Verification Capability、Retention Saga、备份恢复和发布硬化已经先于最小产品闭环落地。

本次重构不采用“继续在旧架构上加开关”的方式，也不采用“一次删除全部旧代码并重写”的方式。正确策略是：

1. 冻结旧控制平面，不再扩展；
2. 复用已经验证的底层协议与安全模块；
3. 在旁路建立一个可独立运行的轻量后台 Service；
4. 先跑通真实 ChatGPT → Service → Codex → Supervisor 闭环；
5. 再把原生 App 切换为 Service 的可视化客户端；
6. 完成真实验收后，按依赖顺序移除旧 Coordinator、Pipeline、Evidence 和 Saga 路径。

最终目标不是追求最少代码，而是只保留对真实产品有直接价值的复杂度。

---

## 2. V1 产品定义

### 2.1 用户可感知的完整流程

1. 用户在 Mac 上安装并启动 Codex Bridge。
2. Bridge 后台 Service 启动本地 MCP，并通过 Secure MCP Tunnel 或用户已有的 HTTPS Tunnel 向 ChatGPT 提供远程 MCP 地址。
3. 用户在 ChatGPT 网页版开发者模式中创建并启用自定义 App。
4. ChatGPT 可以：
   - 查看用户明确注册的本地项目；
   - 搜索和读取项目内允许访问的文件；
   - 查看与项目精确绑定的 Codex Thread；
   - 读取 Thread 的有限历史；
   - 查看当前 Codex 模型和推理强度；
   - 向本机 Codex 提交一个新的开发任务，或继续指定 Thread；
   - 查询、纠偏或停止任务；
   - 获取最终结果和 Supervisor 结论。
5. Service 接受任务后，同时发起：
   - Execution 会话：负责使用本机 Codex 实施任务；
   - Supervisor 会话：负责监督进度、发现偏离并给出纠偏建议。
6. Codex 请求高风险权限时，只允许本机用户在 App 中批准或拒绝。ChatGPT 和 Supervisor 都不能批准。
7. 原生 App 只负责：
   - 连接配置；
   - 项目注册与权限；
   - 任务、Thread、Supervisor 状态展示；
   - 本地审批；
   - 启动、停止或重启后台 Service。
8. 关闭 App 窗口不影响 Service；退出 UI 客户端也不应自动中断正在执行的任务。

### 2.2 V1 必须具备

- 一个独立于 UI 的本机后台 Service；
- 一个远程可达的 MCP 入口；
- 项目白名单和受限文件读取；
- Codex 模型、Thread 和历史读取；
- 新建或继续 Codex 任务；
- Execution 与 Supervisor 并行运行；
- 本机审批允许与拒绝；
- 简单、可查询、可持久化的任务状态；
- App 重开后重新连接 Service 并恢复界面状态；
- 明确的只读 MCP 模式与完整动作 MCP 模式。

### 2.3 V1 明确不做

以下能力不再作为 V1 的前置条件：

- 完整事件溯源状态机；
- Event Sequence CAS 驱动的任务事实重建；
- Git Evidence Saga；
- Finalization Saga；
- 结构化审计报告作为任务完成的硬门；
- Verification 一次性 Capability；
- Exactly-once 通知账本；
- Retention Saga；
- 在线三库备份和崩溃安全恢复；
- 支持包导出；
- 自动恢复失去事件流的旧 Codex Turn；
- 每任务独立 Supervisor 登录身份；
- 同时维护 Local、Manual HTTPS、Secure Tunnel 三套同等级产品路径；
- Developer ID、公证、Staple 和双架构干净机验收作为本地开发闭环的前置条件。

这些能力可以在核心闭环稳定后按真实需求逐项恢复，但不能继续阻塞 V1。

---

## 3. 已确认的架构决策

### D1：后台 Service 是产品核心，App 是客户端

采用独立的用户级后台进程。优先使用 macOS ServiceManagement 管理的 bundled LaunchAgent，并使用 Mach XPC 进行本机 IPC：

```text
ChatGPT Web
    │
    │ Remote MCP
    ▼
CodexBridgeService（LaunchAgent）
    ├── MCPGateway
    ├── TransportManager
    ├── ProjectService
    ├── TaskManager
    ├── ExecutionManager
    ├── SupervisorManager
    ├── ApprovalBroker
    └── SimpleTaskStore
          │
          │ Mach XPC
          ▼
CodexBridge.app（SwiftUI 可视化客户端）
```

Service 由 `launchd` 管理。App 只注册、启动、连接和展示，不持有任务后台生命周期。

### D2：继续使用 Swift，不重写为 TypeScript

保留已经通过真实协议回归的 `BridgeCodexRPC`。重构重点是删除上层控制平面复杂度，而不是重写工作正常的 Codex app-server 适配。

### D3：一个 SQLite 数据库，一个任务状态来源

新 Service 只使用一个 SQLite 数据库。任务当前状态以 `tasks` 表为唯一事实来源；`task_events` 只用于历史展示和诊断，不参与事件归约，也不负责重建当前状态。

建议表：

```text
projects
settings
tasks
task_events
```

本机待审批请求由 Service 内存持有。Service 重启后未决审批失效，对应任务进入 `interrupted` 或 `unknown`，不伪造恢复。Service 异常退出时还必须通过真实进程回归证明其 stdio app-server 子进程会随父进程管道关闭而退出；在这一事实未被证明前，存在旧 `unknown` 写任务的项目不得自动接收新的写任务，必须由本机用户明确处理。

### D4：Execution 与 Supervisor 并行，互不作为对方可用性的硬门

- 接受任务后，在同一个编排步骤中同时请求启动 Execution 和 Supervisor；
- Supervisor 启动失败时，任务进入 `supervision = degraded`，Execution 继续；
- Supervisor 响应不能阻塞 Codex 事件读取；
- Supervisor 不直接批准任何操作；
- Supervisor 默认可以自动发送有限次数的 steer 建议，但不能默认自动停止任务。

### D5：本机用户是 Codex 审批的唯一授权者

- ChatGPT 不能批准；
- Supervisor 不能批准；
- Bridge 不自动批准；
- App 展示 app-server 的有界审批请求；
- 用户选择允许或拒绝后，Service 对原始 app-server request 返回方法对应的响应；
- 未识别的审批类型一律拒绝；
- 不宣称 pathname 变更具备额外的原子执行保证。

### D6：V1 不恢复失去连接的旧 Turn

Service 正常运行时持续持有 Execution 子进程。Service 崩溃或升级导致子进程丢失后：

- 任务标记为 `unknown` 或 `interrupted`；
- 保留 Codex Thread ID；
- 用户可以基于同一 Thread 新建后续任务；
- 不调用新 Turn 冒充旧 Turn 恢复；
- 不为此引入 generation、双锁、恢复 Saga 或事件重建。

### D7：只保留一个远程传输主路径

V1 产品主路径为 Secure MCP Tunnel。开发期允许用户外部启动受信任 Tunnel，或使用 Manual HTTPS 作为验收替代，但不在 Service 内同时维护三套复杂生命周期状态机。

现有 `BridgeTunnel` 暂时保留，不在核心轻量化阶段重写。内置 helper 的签名、供应链和发布打包推迟到真实 MCP 闭环之后。

### D8：支持只读与完整动作两种 MCP 暴露模式

- `readOnly`：只暴露项目、文件、Thread、模型和任务查询；
- `full`：额外暴露任务提交、纠偏和停止。

这是同一套 Service API 的工具目录过滤，不是两套后台实现。

当前 OpenAI 产品边界要求单独验收：个人 Pro 账户目前主要支持 read/fetch MCP，完整 write/modify MCP 需要支持 Full MCP 的工作区。该限制不能通过把动作工具伪装成只读工具绕过。

---

## 4. 目标模块边界

### 4.1 最终建议模块

最终生产目标控制在以下职责范围，不要求第一阶段立即移动所有文件：

```text
BridgeCore
  共享值对象、项目模型、安全规则

BridgeCodex
  app-server RPC、Execution、Supervisor、审批请求解码

BridgeMCP
  MCP HTTP、工具目录、参数解析、结果编码

BridgeServiceCore
  TaskManager、ProjectService、SimpleTaskStore、Transport 协调

BridgeIPC
  XPC 协议、DTO、Service Client

BridgePresentation
  SwiftUI 页面与纯展示模型

CodexBridgeService
  后台 LaunchAgent 可执行入口

CodexBridge.app
  原生 UI 入口
```

不要求为了模块数量机械合并文件。关键要求是单向依赖：

```text
App/UI → BridgeIPC → Service
Service → MCP / Codex / Core / Store
MCP → Service API
Codex → Core
```

禁止 `BridgeApplication` 继续反向依赖 `BridgeMCP` 类型。

### 4.2 复用、改造、旁路和删除矩阵

| 当前模块 | 处理方式 | 说明 |
|---|---|---|
| `BridgeCodexRPC` | 保留 | 继续作为 Codex app-server 协议适配层。只做必要 API 整理，不重写协议。 |
| `BridgeSecurity` | 保留 | 保留路径、敏感内容、出站文本安全边界。删除只服务旧 Evidence 流水线的规则。 |
| `BridgeFiles` | 保留并简化 | 继续提供项目内搜索和读取。保持相对路径、符号链接和敏感文件拒绝。 |
| `BridgeProjects` | 保留并简化 | 保留项目注册、根身份和基础读写/网络策略。去掉与复杂恢复锁耦合的部分。 |
| `BridgeMCP` | 改造 | 保留 HTTP、认证、限流和结果上限；替换工具目录和后台接口。 |
| `BridgeSupervisor` | 改造 | 保留 Decision Schema 与 app-server Review；删除 Durable Ledger 依赖和每任务 HOME 策略。 |
| `BridgeRuntime` | 拆取复用 | 从 `IsolatedCodexTaskRuntime` 和 `CodexTaskSession` 提取轻量 `ExecutionManager`。 |
| `BridgeTunnel` | 暂时保留 | 核心闭环前不重写；发布期再处理 bundled helper 和签名。 |
| `BridgePresentation` | 选择性保留 | 保留可复用页面组件，重新组织为 Service 状态投影。 |
| `BridgeAppModel` | 改造 | 从巨型 Backend 协议改为少量 XPC Service Client 操作。 |
| `BridgeAppShell` | 重写组合根 | 移除后台业务组合，只保留 UI、Service 注册、XPC、系统面板。 |
| `BridgeCoordinator` | 旁路后删除 | 不再作为新任务运行时依赖。 |
| `BridgePipeline` | 旁路后删除 | 不再作为完成和 Supervisor 的硬门。 |
| `BridgeVerification` | 移出 V1 | Codex 可以在任务中运行测试；Bridge 暂不建立第二套验证执行器。 |
| `BridgeReporting` | 移出 V1 | 最终结果由 `TaskRecord.resultSummary`、最近事件和 Supervisor 结论组成。 |
| `BridgePersistence` | 替换 | 旧 EventStore 冻结；新建简单单库 Store。 |
| `BridgeRepositories` | 替换 | 项目和任务进入新单库，不再维护多仓库一致性。 |
| `BridgeGit` | 大幅简化 | V1 只保留可选 `git diff --stat` 与变更文件列表，不持久化 Patch LRU。 |
| 备份、Retention、Support Bundle | 暂停 | 不接入新 Service，待核心闭环后按真实需求重做。 |

---

## 5. 新的 Service 数据模型

### 5.1 TaskRecord

```swift
struct TaskRecord: Sendable, Codable, Identifiable {
  let id: String
  let projectID: String
  let source: TaskSource
  let prompt: String
  let requestedThreadID: String?

  var codexThreadID: String?
  var codexTurnID: String?
  var status: TaskStatus
  var supervisorStatus: SupervisorStatus

  let executionModel: String
  let executionEffort: String
  let supervisorModel: String?
  let supervisorEffort: String?
  let permissionMode: PermissionMode
  let networkAllowed: Bool

  var currentStep: String?
  var changedFiles: [String]
  var resultSummary: String?
  var supervisorSummary: String?
  var failureCode: String?

  let createdAt: Date
  var updatedAt: Date
}
```

字段必须保持有界。项目绝对路径不得通过 MCP 或 XPC 的非本机展示接口泄露。

### 5.2 状态枚举

```text
TaskStatus
  awaitingLocalApproval
  starting
  running
  waitingForCodexApproval
  completed
  failed
  interrupted
  unknown

SupervisorStatus
  disabled
  starting
  running
  degraded
  completed
```

禁止把 Supervisor 活动伪装成任务生命周期阶段。

### 5.3 TaskEvent

```text
taskCreated
taskApproved
executionStarting
executionStarted
planUpdated
commandCompleted
fileChanged
approvalRequested
approvalResolved
supervisorStarted
supervisorDecision
supervisorDegraded
turnCompleted
taskCompleted
taskFailed
taskInterrupted
```

事件用于展示和排错，不作为当前状态的唯一来源。每次状态变更在一个 SQLite 事务中同时更新 `tasks` 并追加 `task_events`。

### 5.4 ProjectRecord

继续复用现有项目 ID、根目录身份和基础权限策略：

```text
read: denied | allowed
write: denied | ask | allowed
network: denied | ask | allowed
```

V1 不维护 Worktree 自动创建、双锁或多根卷恢复。存在写任务时，同一项目只允许一个 active write task；实现为 TaskManager 内存锁，并在数据库中通过 active task 查询进行启动前复核。

---

## 6. MCP 工具重新设计

### 6.1 V1 核心工具目录

优先沿用现有工具名，减少无意义的协议迁移：

```text
bridge_status
list_projects
get_project
search_project_files
read_project_file
list_threads
read_thread
list_models
get_task
submit_task
steer_task
interrupt_task
```

处理方式：

- `get_task_events`：第一轮不暴露；`get_task` 返回最近有界事件。真实使用证明需要独立分页后再恢复。
- `get_task_diff`：第一轮不暴露；`get_task` 返回变更文件与可选 diff stat。
- `get_final_report`：移除硬依赖；终态 `get_task` 直接返回结果和 Supervisor 总结。
- `open_in_codex`：只保留为 App 本地操作，不向 ChatGPT 暴露。

### 6.2 `submit_task` 输入

建议替换当前大量必填数组：

```json
{
  "project_id": "project-id",
  "prompt": "修复登录错误处理并运行相关测试",
  "thread_id": null,
  "execution_model": null,
  "execution_effort": null,
  "supervisor_model": null,
  "supervisor_effort": null,
  "permission_mode": "workspace-write",
  "network_access": false,
  "acceptance_criteria": ["相关测试通过"],
  "client_request_id": null
}
```

规则：

- 仅 `project_id` 和 `prompt` 必填；
- 模型和 effort 未提供时使用用户在 App 中保存的项目默认值；
- 未设置默认值且目录无法推断时返回明确错误，不静默替换用户明确选择；
- `thread_id` 为空时创建新 Thread；
- `client_request_id` 可选，提供时用于幂等复用；未提供时由 Service 生成任务 ID；
- `network_access` 默认 `false`；
- `permission_mode` 默认读取项目策略，不在 MCP Schema 中制造两套拼写；
- `acceptance_criteria` 可选且有界。

### 6.3 `get_task` 输出

至少包含：

```text
task_id
status
project_id
codex_thread_id?
codex_turn_id?
current_step?
changed_files[]
recent_events[]
supervisor_status
supervisor_summary?
local_approval_required
result_summary?
failure_code?
updated_at
```

不得返回原始凭证、绝对项目路径、未过滤的完整进程输出或 Supervisor 的内部认证目录。

### 6.4 工具权限标记

- 查询和读取工具：`readOnlyHint = true`；
- `submit_task`、`steer_task`：`readOnlyHint = false`、`destructiveHint = false`；
- `interrupt_task`：`readOnlyHint = false`、`destructiveHint = true`；
- 不得为了兼容个人套餐把动作工具伪装成只读工具。

---

## 7. Execution 运行模型

### 7.1 从现有 Runtime 提取的能力

从 `BridgeRuntime/IsolatedCodexTaskRuntime.swift` 和 `CodexTaskSession.swift` 提取：

- 精确项目 cwd；
- 动态模型和 effort 校验；
- 新建 Thread；
- 读取并继续已有 Thread；
- `turn/start`；
- 单消费者 app-server 事件流；
- `turn/steer`；
- `turn/interrupt`；
- 审批请求解码和响应；
- 进程停止、超时和回收；
- 有界 stdout、stderr 和事件队列。

不带入：

- preparation reservation；
- provisional/exact 双锁替换；
- generation；
- EventStore CAS；
- Pipeline lifecycle；
- Git baseline；
- finalization authorization；
- 恢复 reconciliation。

### 7.2 新 ExecutionManager 接口

```swift
protocol ExecutionManaging: Sendable {
  func start(_ request: ExecutionRequest) async throws -> ExecutionHandle
  func steer(taskID: String, expectedTurnID: String, text: String) async throws
  func interrupt(taskID: String, expectedTurnID: String?) async throws
  func resolveApproval(_ decision: LocalApprovalDecision) async throws
  func stopAll() async
}
```

`ExecutionHandle` 只包含：

```text
taskID
threadID
turnID
events: AsyncStream<ExecutionEvent>
```

每个任务一个 Execution app-server 进程。V1 不做进程池。

### 7.3 审批行为

- Execution 使用当前 app-server 支持的 `on-request` 策略；
- 审批请求绑定 `taskID + requestID + threadID + turnID + itemID/approvalID`；
- Service 保存原始强类型 request envelope，App 只收到有界展示 DTO；
- App 允许或拒绝后，Service 使用原始 request ID 返回对应响应；
- 只允许本地 XPC 客户端调用审批接口；
- 审批超时后拒绝并使任务进入明确失败或等待状态；
- 不实现自动审批；
- 不再因为缺少额外“原子操作证据”而禁止本机用户手动允许。

---

## 8. Supervisor 运行模型

### 8.1 认证与进程

V1 使用一个持久化 Supervisor Profile：

```text
~/Library/Application Support/CodexBridge/SupervisorProfile
```

实际路径由 Service 私有数据根决定，目录权限保持 `0700`。Bridge 只通过官方 app-server 登录流程完成认证，不读取、复制或解析认证文件。

这套 Profile 在个人 V1 中属于**受信任本机运行模式**，不能宣传成已经证明的凭证隔离安全边界。当前 app-server 尚未验证可以关闭全部核心文件读取工具，同一 Supervisor 进程理论上可能读取自己被允许访问的 Profile。V1 通过“不发送项目源码或项目根、只发送 Bridge 生成的有界摘要、固定 scratch cwd、禁网 Turn、输出过滤和本机用户显式启用”降低风险；公开发布前必须通过虚假凭证 canary 回归，或确认新的 no-tools/restricted-tools 协议能力，否则界面和 README 必须诚实标记该限制。

采用一个长期运行、与 Execution 完全独立的 Supervisor app-server 进程：

- 一个进程；
- 每个 Task 一个独立 Supervisor Thread；
- 固定 read-only；
- 固定 `approvalPolicy = never`；
- 默认无网络；
- cwd 使用空的私有 scratch 目录，不使用项目根；
- Supervisor 只接收 Bridge 生成的有界任务事件摘要。

这比“每任务创建 HOME、重新登录、任务结束删除 HOME”更符合个人工具的真实使用。

### 8.2 非阻塞事件路径

禁止以下同步链：

```text
Codex Event → await Supervisor → 再读取下一个 Codex Event
```

新路径：

```text
Codex Event
  ├── 更新 TaskStore
  ├── 返回 Execution 事件读取循环
  └── 异步投入 SupervisorManager 队列
```

`SupervisorManager.observe(event:)` 必须快速入队后返回。Supervisor review 超时或失败只更新 `SupervisorStatus.degraded`。

### 8.3 Supervisor 输入

只发送：

- 用户任务 prompt；
- 可选 acceptance criteria；
- Codex 当前计划摘要；
- 已完成命令摘要；
- 变更文件相对路径；
- 审批请求类型和结果；
- 测试结果摘要；
- Codex 最终回复。

默认不发送源文件全文、绝对路径、账号信息或原始环境变量。

### 8.4 Supervisor 输出

简化为：

```json
{
  "decision": "continue | steer | attention | final_review",
  "risk": "low | medium | high",
  "summary": "...",
  "instruction": null
}
```

规则：

- `continue`：不操作；
- `steer`：在 active turn 精确匹配时可自动发送；
- `attention`：通知本机用户，不自动 interrupt；
- `final_review`：保存最终监督结论；
- 每任务自动 steer 有硬上限；
- 相同问题必须去重；
- 自动 steer 有冷却时间；
- Supervisor 不能批准操作；
- Supervisor 失败不终止 Execution。

初始建议值：每任务最多自动 steer 3 次。该值必须在真实任务中验证后再调整。

---

## 9. App 与 Service 的职责切分

### 9.1 Service 负责

- MCP server；
- Tunnel 生命周期；
- 项目和设置持久化；
- Codex Thread/模型查询；
- Execution 子进程；
- Supervisor 子进程；
- 任务状态；
- 待审批请求；
- 任务操作；
- 对 App 提供本机 XPC API。

### 9.2 App 负责

- 注册、启动、停止、查看 Service；
- 项目目录选择；
- 项目权限编辑；
- Tunnel 配置输入；
- Codex 与 Supervisor 登录入口；
- 任务和 Thread 列表；
- 本机审批；
- 用户主动打开 Codex Thread；
- 设置默认模型和 effort。

### 9.3 App 页面精简

建议保留五个顶层页面：

```text
Overview
Projects
Tasks
Connections
Settings
```

调整：

- Threads 作为 Projects 或 Tasks 内的二级视图；
- Approvals 作为 Tasks 页面中的高优先级区，而不是独立控制平面；
- Logs 只保留简短 Service 诊断，不暴露原始进程输出；
- 九步 Onboarding 压缩为：系统检查、连接、项目三步；
- 删除 App 内本地任务编排器，ChatGPT 是主要任务入口；开发调试可保留隐藏的本机测试入口。

### 9.4 XPC API

初始只需要：

```text
serviceStatus()
listProjects()
registerProject(path)
updateProjectPolicy()
listThreads(projectID)
readThread(projectID, threadID)
listModels()
listTasks()
getTask(taskID)
listPendingApprovals()
resolveApproval()
startServiceTransport()
stopServiceTransport()
```

App 使用定时刷新即可完成 V1，不在第一阶段引入双向 XPC 事件推送。窗口可见时短间隔刷新，后台时降低频率。真实体验证明有必要后，再增加回调接口。

XPC 协议使用 `@objc` 接口。简单标识符直接使用 Foundation 基础类型，复杂请求和快照统一使用带 `schema_version` 的有界 Codable `Data` 包；单包设硬上限并在 Service 侧 fail-closed 解码。不要同时维护 `NSSecureCoding` 对象模型和 JSON/Data 两套 IPC Schema。由于 App 不启用 Sandbox，项目目录通过本机 XPC 传递用户选择的绝对路径，由 Service 重新规范化、捕获根身份并存储；该绝对路径绝不进入远程 MCP 输出。

---

## 10. 分阶段实施计划

每个阶段必须独立构建、测试和提交。前一阶段未通过验收，不进入下一阶段。

### Phase 0：重置项目权威基线

#### 目标

阻止旧 V2.0 控制平面目标继续驱动新开发。

#### 改动

- 更新根 `AGENTS.md`：
  - 将本文定义的轻量 V1 设为当前产品目标；
  - 将旧 V2.0 方案标记为历史硬化参考；
  - 明确禁止为 V1 新增 Saga、Ledger、Evidence Store 和第二套恢复系统；
  - 压缩已超过约 250 行的长期记忆，删除已过时的实现细节。
- 更新 `README.md`：
  - 描述真实目标和当前重构状态；
  - 不再把旧控制平面功能数量作为完成度；
  - 明确 Full MCP 的外部账户限制。
- 冻结：
  - `ChatGPT-Codex-Bridge-原生Swift本地开源版完整方案-V2.0.md`；
  - `docs/PHASE_LEDGER.md`；
  - `docs/FOLLOW_UP_PLAN.md`。
- 不删除旧文档，只增加明确的 Legacy 标记和本文链接。

#### 验收

- 新开发者只读 `AGENTS.md`、`README.md` 和本文即可准确理解 V1；
- 权威来源不再互相冲突；
- 无源码行为变化。

#### 回滚

只涉及文档，可单提交回滚。

---

### Phase 1：建立新 Service Core，保持旧运行时不变

#### 目标

创建旁路的新数据模型和 Store，不触碰旧 MCP/任务执行路径。

#### 新增建议路径

```text
Packages/BridgeCore/Sources/BridgeServiceCore/
  ServiceModels.swift
  SimpleTaskStore.swift
  ProjectService.swift
  TaskManager.swift
  ServiceSettings.swift

Packages/BridgeCore/Tests/BridgeServiceCoreTests/
```

#### 改动

- 在 `Package.swift` 新增 `BridgeServiceCore` target；
- 继续使用 GRDB，不增加数据库依赖；
- 实现单库 schema：`projects/settings/tasks/task_events`；
- 实现 TaskRecord 的事务更新与事件追加；
- 实现项目 active write task 查询；
- 实现 Service 重启时把 `starting/running/waitingForCodexApproval` 任务标记为 `unknown`；
- 不接入 UI、MCP、Codex 或 Supervisor。

#### 测试

- 新库创建和迁移；
- 任务状态更新与事件同时提交；
- 并发启动同一项目写任务只允许一个；
- 不同项目可并行；
- 重启后活动任务进入 `unknown`；
- 无事件归约、无快照重建、无多库事务。

#### 验收

- 新 target 可以单独测试；
- 旧全量测试仍通过；
- 旧运行时没有引用新 Store。

#### 回滚

删除新 target 即可，不影响现有 App。

---

### Phase 2：提取轻量 ExecutionManager

#### 目标

从现有 Runtime 提取可以独立启动 Codex 任务的最小执行层。

#### 新增建议路径

```text
Packages/BridgeCore/Sources/BridgeCodexService/
  ExecutionManager.swift
  ExecutionSession.swift
  ExecutionEvent.swift
  LocalApprovalBroker.swift
```

#### 改动

- 复用 `BridgeCodexRPC`；
- Execution 必须使用用户现有的官方 Codex 可执行文件、`HOME`/`CODEX_HOME` 与 ChatGPT 登录事实，以保留真实模型目录和已有 Thread；Service 只负责启动 app-server，绝不读取、复制或解析 `auth.json`；
- LaunchAgent 不得依赖交互式 Shell 的 `PATH`，Codex 可执行文件和 Execution 环境必须由系统检测结果显式构造；
- 从 `IsolatedCodexTaskRuntime` 和 `CodexTaskSession` 提取：
  - model/list 校验；
  - Thread start/read/resume；
  - Turn start；
  - 事件解析；
  - steer/interrupt；
  - approval request/response；
  - stop/reap；
- 通过 `ExecutionManaging` 接口暴露；
- 使用一个真实 `TaskEvent` 回调更新新 TaskManager；
- 暂不接入 MCP。

#### 测试

使用现有 fake app-server fixture 验证：

- 新建 Thread；
- 继续已有 Thread且 cwd 精确匹配；
- 模型或 effort 不存在时明确失败；
- workspace-write 与 read-only 正确映射；
- matching `turn/started` 后才允许 steer/interrupt；
- approval request 在 App 决定后能够允许和拒绝；
- 未知审批请求拒绝；
- 进程退出会结束事件流并更新任务失败；
- 强制终止承载 Service 的测试进程后，Execution app-server 因 stdio/监护边界退出，不留下继续修改项目的孤儿进程；
- 同一任务不重复启动。

#### 验收

- 一个测试任务能够在不经过 `BridgeCoordinator` 和 `BridgePipeline` 的情况下完成；
- 允许审批路径有真实测试；
- 旧 Runtime 尚未删除。

#### 回滚

新 Manager 尚未接入生产组合，可直接移除。

---

### Phase 3：实现独立、非阻塞 SupervisorManager

#### 目标

建立真正独立的监督进程，并证明它不会阻塞或终止 Execution。

#### 新增/改造

```text
BridgeCodexService/
  SupervisorManager.swift
  SupervisorSession.swift
  SupervisorEventQueue.swift

BridgeSupervisor/
  保留 SupervisorDecision
  简化 CodexSupervisorRuntime
```

#### 改动

- 使用持久 Supervisor Profile；
- 一个 Supervisor app-server 进程，多任务独立 Thread；
- TaskManager 接受任务时同时调用 ExecutionManager 和 SupervisorManager；
- Execution 事件通过 Supervisor 内部 actor 队列异步提交；
- 删除 Supervisor review 对 Execution 事件读取循环的同步等待；
- Supervisor 失败只更新 `degraded`；
- 实现 continue/steer/attention/final_review；
- 自动 steer 上限和去重仅保存在任务内存状态，任务结束后清理。

#### 测试

- Supervisor 启动超时，Execution 仍能完成；
- Supervisor 进程退出，Execution 不被 interrupt；
- Supervisor 慢响应不阻塞连续 Execution 事件；
- steer 只发送给精确 active turn；
- 第四次自动 steer 被拒绝；
- Supervisor 审批请求立即拒绝；
- final review 保存到 TaskRecord；
- 两个任务的 Supervisor Thread 不串上下文。

#### 验收

- 任务启动后能同时观察到 `execution = starting` 和 `supervisor = starting/running`；
- 主任务完成不依赖 Supervisor final_accept；
- Supervisor 是增益能力，不是全局门禁。

#### 回滚

关闭 Supervisor feature flag，Execution 仍可单独运行。

---

### Phase 4：建立轻量 MCP 工具适配

#### 目标

让现有 MCP HTTP 层直接调用新 Service API，而不是 `BridgeApplication → Coordinator → Pipeline`。

#### 改动

- 新建 `BridgeServiceAPI` 协议；
- `BridgeMCP` 只依赖该协议和 MCP DTO；
- 删除 `BridgeApplication` 对 `BridgeMCP` 的反向依赖；
- 工具目录精简为 12 个核心工具；
- 简化 `submit_task` Schema；
- `get_task` 返回最近事件和 Supervisor 状态；
- 保留现有：
  - 回环监听；
  - Path/Header 认证；
  - 请求和响应上限；
  - 全局和单 session 并发限制；
  - 超时和 session 清理；
- 增加 `readOnly/full` 工具目录模式。

#### 测试

- MCP Inspector 初始化和 tools/list；
- 只读模式看不到动作工具；
- full 模式准确包含动作工具；
- ChatGPT 提交任务后返回 `task_id`；
- 重复 `client_request_id` 复用相同任务；
- `get_task` 能观察状态和 Supervisor；
- 绝对路径、未知项目和越界读取被拒绝；
- `steer_task` 和 `interrupt_task` 绑定精确 active turn；
- MCP 不能调用本机审批。

#### 验收

- 使用 MCP Inspector 跑通：

```text
list_projects
list_threads
list_models
submit_task
get_task
steer_task
interrupt_task
```

- 全流程不进入旧 Coordinator/Pipeline。

#### 回滚

旧 MCP backend 保留一个阶段，通过编译配置切回；禁止长期双写任务数据。

---

### Phase 5：创建 CodexBridgeService 后台可执行 Target

#### 目标

把 MCP、TaskManager、Execution、Supervisor 和 Transport 从 App 进程迁出。

#### 新增建议路径

```text
Service/
  CodexBridgeServiceMain.swift
  CodexBridgeServiceDelegate.swift
  ServiceComposition.swift
  ServiceXPCListener.swift
  Info.plist

Packages/BridgeCore/Sources/BridgeIPC/
  BridgeServiceXPCProtocol.swift
  BridgeServiceClient.swift
  BridgeServiceDTO.swift

Config/
  org.codexbridge.service.plist
```

#### 改动

- 新增 `CodexBridgeService` executable target；
- Service 支持 `--foreground` 开发运行模式；
- 使用 `SMAppService` 注册 bundled LaunchAgent；
- 使用 `NSXPCListener` / `NSXPCConnection(machServiceName:)` 提供本机 API；
- XPC 只接受同一用户会话连接；
- Service 启动时打开单库、恢复项目和任务快照；
- App 不再创建 `DesktopComposition`；
- App 退出只关闭 XPC 客户端，不调用 Service 的 `stopAll()`；
- 明确的“停止后台服务”操作才关闭 MCP、Tunnel、Execution 和 Supervisor。

#### 测试

- UI 进程启动 Service；
- UI 退出后 Service PID、MCP 和活动任务仍存在；
- 重新打开 UI 后能读取原任务；
- 两个 UI 连接不会创建两个 Service；
- 非同 UID 连接被拒绝；
- Service 明确停止时按顺序关闭 listener、任务和子进程；
- 模拟 Service 崩溃后，不存在仍在运行并可能继续写项目的 Execution/Supervisor 孤儿进程；若当前 Codex 版本不能保证这一点，Service 重启后必须阻止相关项目的新写任务并要求本机处理；
- `--foreground` 可用于 CI 和本机集成测试。

#### 验收

- 关闭 App 窗口不影响任务；
- 退出 App 后任务继续；
- 重新打开 App 能重新连接；
- Service 是唯一任务状态拥有者。

#### 回滚

保留旧 App 内组合一个阶段，但同一构建只能启用一个 backend，禁止两个 backend 同时操作同一项目。

---

### Phase 6：把 App 改为纯 Service 客户端

#### 目标

移除 `LiveBridgeAppBackend` 的后台职责，精简 UI。

#### 改动

- 将 `BridgeAppBackend` 拆成少量 Service Client 操作，不再包含备份、Retention、Evidence 和本地任务编排；
- 用 `BridgeServiceClient` 替换 `LiveBridgeAppBackend`；
- 删除 App 内：
  - `DesktopComposition`；
  - MCP runtime；
  - Tunnel runtime；
  - Execution runtime；
  - Supervisor runtime；
  - Task lifecycle coordinator；
- 页面收敛为 Overview、Projects、Tasks、Connections、Settings；
- Tasks 页面显示：
  - Execution 状态；
  - Supervisor 状态；
  - 最近事件；
  - 变更文件；
  - 待审批；
  - steer/interrupt；
- Onboarding 压缩为三步；
- App 不再提供一套与 ChatGPT 重复的本地任务 Composer。

#### 测试

- UI 在 Service 不可用时显示连接失败，而不是创建隐式本地 backend；
- 项目注册通过 XPC 生效；
- Pending approval 能允许和拒绝；
- UI 退出不调用 Service shutdown；
- Service 重启后 UI 自动重新连接；
- 轻/深色和基本无障碍不回退。

#### 验收

- App 源码不直接 import `BridgeRuntime`、`BridgePipeline`、`BridgeCoordinator`；
- App 不持有 Codex child process；
- App 只通过 IPC 修改 Service 状态。

#### 回滚

保留上一个可运行 tag；不要在 UI 切换尚未完成时删除旧页面。

---

### Phase 7：真实 ChatGPT 和 Tunnel 闭环

#### 目标

用真实 ChatGPT Developer Mode 验证产品，而不是只通过 Inspector。

#### 前置

- Bridge Service 本地 MCP 正常；
- 用户提供真实 Tunnel 配置；
- ChatGPT 工作区支持目标 MCP 权限；
- Runtime Key、Authorization、Codex 登录信息只由用户在本机输入，不写入仓库。

#### 验收顺序

1. ChatGPT 扫描工具目录；
2. 调用 `bridge_status`；
3. 调用 `list_projects`；
4. 调用 `list_threads` 和 `read_thread`；
5. 调用 `list_models`；
6. 提交最小 read-only 任务；
7. 查询 `get_task`，确认 Supervisor 独立运行；
8. 提交 workspace-write 任务；
9. 在 App 中批准任务启动和必要 Codex 审批；
10. 使用 `steer_task` 修正 active turn；
11. 获取终态结果和 Supervisor 总结；
12. 退出 UI，确认 Service 和任务不停止；
13. 断开 Tunnel，确认本地任务继续、新远程任务拒绝；
14. 恢复 Tunnel，确认健康后重新接收。

#### 验收

- ChatGPT 完整闭环至少成功执行一个真实项目任务；
- 没有依赖旧 Coordinator/Pipeline；
- Supervisor 故障测试不会中止 Execution；
- ChatGPT 不能批准本机操作。

#### 停止条件

出现以下任一情况，不进入旧代码删除阶段：

- ChatGPT 工具 Schema 经常调用失败；
- Service 退出 UI 后不能稳定运行；
- 本机允许审批仍无法让 Codex 继续；
- Supervisor 阻塞 Execution；
- Thread 与项目 cwd 可能串绑；
- Tunnel 断线会中断本地任务。

---

### Phase 8：数据迁移与生产切换

#### 目标

将当前用户项目配置迁移到新单库，停止旧运行时写入。

#### 迁移范围

迁移：

- 已注册项目；
- 项目根和名称；
- 基础读写/网络策略；
- 连接模式的非秘密配置；
- 默认模型和 effort 设置。

不迁移：

- 旧任务事件；
- Pipeline Artifact；
- Supervisor Ledger；
- Verification Capability；
- Git Patch Store；
- 通知 Ledger；
- Retention Job；
- Support Bundle；
- 旧恢复状态。

#### 迁移方式

- 新 Service 首次启动时只读打开旧数据库；
- 在一个新数据库事务中导入允许字段；
- 写入 `legacy_import_completed` 标记；
- 不修改或删除旧数据库；
- 用户确认新版本稳定前保留旧数据目录；
- 不实现长期双写。

#### 验收

- 项目数量、名称和权限一致；
- 不导入绝对路径到 MCP 输出；
- 密钥仍只在 Keychain；
- 重复启动不会重复导入；
- 迁移失败不会产生半导入状态。

#### 回滚

关闭新 Service，重新启用旧构建即可读取未被修改的旧数据库。

---

### Phase 9：删除旧控制平面

#### 前置条件

必须同时满足：

- 新 Service 真实 ChatGPT 闭环通过；
- App 已完全使用 XPC；
- 数据迁移通过；
- 新路径稳定运行；
- 有可回退 Git tag；
- 旧模块不再被生产 target import。

#### 删除顺序

1. 删除旧 App 组合：
   - `LiveBridgeAppBackend` 的旧后台路径；
   - `DesktopComposition`；
   - 旧 Desktop MCP/Connection/Task lifecycle 组合。
2. 删除旧完成流水线：
   - `BridgePipeline`；
   - `BridgeReporting`；
   - `BridgeVerification`。
3. 删除旧任务控制平面：
   - `BridgeCoordinator`；
   - 旧 `BridgePersistence/EventStore*`；
   - 旧 `BridgeRepositories`。
4. 简化 Git：
   - 删除持久化 Patch LRU 和 retention manifest；
   - 保留最小 Git summary 实现。
5. 删除旧 UI：
   - Evidence workspace；
   - Backup/Restore；
   - Retention；
   - Support Bundle；
   - 独立 Approvals/Logs 控制页中不再需要的部分。
6. 清理 `Package.swift` 产品和 target；
7. 删除不再被引用的 fixture、测试和文档；
8. 更新 README、架构图和发布说明。

#### 删除原则

- 每次只删除一组已经没有生产引用的模块；
- 每组删除后运行全量测试和 App/Service 构建；
- 禁止保留“以后可能用到”的旧实现；
- Git 历史就是归档，不在源码中保留两套运行路径。

---

### Phase 10：发布硬化

只有核心闭环稳定后再处理：

- 内置并签名 Secure MCP Tunnel helper；
- Developer ID；
- Hardened Runtime；
- Notarization；
- Staple；
- Universal 2；
- Apple Silicon 和 Intel 干净机；
- Hosted CI；
- Service 升级和 LaunchAgent 替换；
- 正式备份/恢复需求；
- 支持包；
- 通知；
- 更完整的 VoiceOver 和 Reduced Motion 矩阵。

这些工作不得重新进入 TaskManager 核心状态机。

---

## 11. 测试与验收矩阵

### 11.1 每次提交的最低检查

```bash
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive \
  Packages/BridgeCore/Sources Packages/BridgeCore/Tests
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridge \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/Xcode \
  build CODE_SIGNING_ALLOWED=NO
Scripts/verify-mcp-inspector.sh
```

Service target创建后补充：

```bash
Scripts/with-xcode.sh xcodebuild \
  -project CodexBridge.xcodeproj \
  -scheme CodexBridgeService \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeService \
  build CODE_SIGNING_ALLOWED=NO
```

应新增一个真实进程集成脚本：

```text
Scripts/verify-service-e2e.sh
```

它至少验证：启动 Service、MCP tools/list、提交 fake Codex 任务、Supervisor 故障降级、UI/XPC 重连、Service 正常关闭。

### 11.2 必须有的真实行为测试

- 文件读取不能逃逸项目根；
- Thread cwd 必须属于项目；
- App 退出不终止任务；
- Service 重复启动只有一个实例；
- Supervisor 卡死不阻塞 Execution；
- 本机允许审批能让 Codex 继续；
- ChatGPT、MCP 和 Supervisor 都不能批准；
- Tunnel 断线不停止本地任务；
- 同一项目不同时运行两个写任务；
- Service crash 后不伪造旧 Turn 恢复，且不会留下继续写项目的孤儿 Codex 进程；
- 新任务可以继续原有 Thread；
- 模型目录变化时明确失败，不静默替换已选模型；
- 工具目录在 readOnly/full 模式下准确；
- MCP 输出不泄露绝对路径或凭证。

### 11.3 禁止的假测试

- 只断言 Mock 方法被调用；
- 用空实现代替真实 SQLite 状态变化；
- 用提示词声称 Supervisor 只读；
- 把 Inspector 通过当作真实 ChatGPT 通过；
- 把 App 本地 ready 当作 Tunnel 远程 ready；
- 把新 Turn 当作旧 Turn 恢复；
- 把 Supervisor 返回自然语言当作任务完成事实。

---

## 12. Git 与提交策略

建议提交序列：

```text
docs: rebaseline Codex Bridge as a lightweight local service
feat: add simple service task store
refactor: extract standalone Codex execution manager
feat: add non-blocking supervisor manager
refactor: connect MCP tools to lightweight service API
feat: add CodexBridgeService launch agent and XPC API
refactor: make macOS app a service client
feat: import legacy project configuration
chore: remove legacy coordinator and pipeline runtime
chore: remove obsolete evidence and retention modules
```

规则：

- 每个提交必须独立构建和测试；
- 不提交未完成且默认启用的生产路径；
- 不把计划、临时日志、测试垃圾和凭证混入功能提交；
- 大规模删除前创建可回退 tag；
- 不使用长期双写兼容；
- 不在一个提交中同时引入 Service、切换 UI、迁移数据和删除旧模块。

本文是计划文件，本轮不自动提交。

---

## 13. 风险登记

| 风险 | 影响 | 控制方式 |
|---|---|---|
| app-server 协议继续变化 | Execution 或 Thread 操作失败 | 保留 `BridgeCodexRPC` 适配层和真实 fixture；不把协议字段散落到 Service。 |
| XPC/LaunchAgent 开发签名配置复杂 | Service 无法由 App 管理 | Phase 5 先用 `--foreground` 验证业务，再接 ServiceManagement；生产只保留一种 IPC。 |
| Supervisor 可能读取其自身 Profile | 凭证风险 | 个人 V1 明确标记为受信任本机模式；不发送项目源码、使用 scratch cwd、禁网 Turn 和输出过滤；公开发布前必须通过虚假凭证 canary 或获得已验证的 no-tools/restricted-tools 能力。 |
| Supervisor 速度慢 | 阻塞主任务 | 强制异步队列，Supervisor 失败只降级。 |
| Codex 审批信息不足 | 用户无法判断风险 | 明确显示请求类型、命令/路径摘要和来源；不自动允许；未知类型拒绝。 |
| Service 崩溃导致任务中断 | 任务丢失 | V1 诚实标记 unknown/interrupted，保留 Thread ID；不引入伪恢复。 |
| ChatGPT 工作区不支持 Full MCP | 无法调用任务动作 | 提供 readOnly 模式；full 模式在支持的 Business/Enterprise/Edu 工作区验收。 |
| ChatGPT 工具定义缓存 | Schema 更新后调用失败 | 开发期重新 Scan Tools；发布后按工作区规则刷新或重建 App。 |
| 旧数据迁移损坏 | 项目配置丢失 | 只读导入旧库，新库事务写入，旧数据不修改。 |
| 两套 runtime 长期并存 | 状态竞争和维护翻倍 | 仅在短期切换阶段保留，通过编译配置二选一，不双写。 |
| 轻量化变成再次重写 | 周期失控 | 先复用底层模块，按阶段旁路；禁止引入新语言和新基础设施。 |

---

## 14. 工程约束

新代码必须遵守：

- 函数嵌套不超过 3 层；
- 一个状态只有一个拥有者；
- UI 不拥有后台任务；
- Supervisor 不拥有 Execution；
- MCP 不直接操作 Codex 进程，必须经 Service API；
- 不新增循环依赖；
- 不新增 Saga、Ledger、Evidence Store、Capability Store；
- 不新增数据库；
- 不增加 Node/TypeScript 运行时；
- 新文件达到约 600 行时必须评估拆分，不能重现 1,000 行以上巨型组合文件；
- 所有文本、列表、进程输出和事件队列都有上限；
- 所有外部标识符都验证长度和控制字符；
- 不读取 `auth.json`、Keychain 内容、浏览器 Cookie、Token 或无关目录；
- 不自动批准网络、项目外访问、删除、生产迁移或凭证读取；
- 真实测试优先于模拟调用次数。

---

## 15. 明确禁止的实施方式

- 直接把 `productionReviewAvailable` 从 `false` 改成 `true`；
- 在旧 `TaskCoordinator` 上继续叠加 Service/XPC 特例；
- 让 Supervisor 继续同步阻塞 Execution 事件循环；
- 为了“兼容”同时写旧 EventStore 和新 SimpleTaskStore；
- 一次性删除全部旧代码后再尝试构建；
- 把 App 隐藏窗口误称为独立后台 Service；
- 让 ChatGPT 或 Supervisor调用本机审批接口；
- 把动作工具标为只读；
- 为 V1 重做一套新的 Git Evidence、Verification 或 Final Report 系统；
- 在核心闭环未通过前投入签名、公证、备份恢复和完整视觉重设计；
- 遇到 app-server 行为不确定时用自然语言猜测协议。

---

## 16. V1 完成定义

只有下列条件全部满足，才能认为轻量 V1 完成：

- [ ] ChatGPT 能通过远程 MCP 连接本机 Service；
- [ ] ChatGPT 能列出注册项目；
- [ ] ChatGPT 能在安全边界内搜索和读取项目文件；
- [ ] ChatGPT 能列出和读取项目绑定的 Codex Thread；
- [ ] ChatGPT 能读取真实模型目录和 effort；
- [ ] ChatGPT 能提交一个 Codex 任务；
- [ ] Execution 与 Supervisor 在同一任务启动步骤中分别进入 starting/running；
- [ ] Supervisor 故障不会停止 Execution；
- [ ] 本机 App 能允许和拒绝 Codex 审批；
- [ ] ChatGPT 和 Supervisor 都不能批准；
- [ ] ChatGPT 能 steer 和 interrupt 精确 active turn；
- [ ] `get_task` 能返回任务状态、最近事件、变更文件、结果和 Supervisor 总结；
- [ ] 关闭或退出 UI 不会停止 Service 和活动任务；
- [ ] 重新打开 UI 能恢复 Service 状态；
- [ ] Service 只使用一个 SQLite 数据库；
- [ ] 新生产路径不依赖 `BridgeCoordinator`、`BridgePipeline`、`BridgeVerification`、`BridgeReporting` 和旧 EventStore；
- [ ] 旧项目配置已安全导入，新旧数据库没有长期双写；
- [ ] MCP Inspector、Service 真实进程集成测试、App 构建和真实 ChatGPT 闭环全部通过；
- [ ] README、AGENTS.md 和架构文档与代码事实一致。

---

## 17. 第一轮实际执行范围

第一轮只执行 Phase 0 和 Phase 1：

1. 重置文档权威基线；
2. 新增 `BridgeServiceCore`；
3. 建立单库任务模型和真实测试；
4. 不切换现有 App；
5. 不删除旧模块；
6. 不修改 Tunnel；
7. 不打开 Supervisor 生产门禁；
8. 全量测试、格式检查和 App 构建通过后提交独立 Git commit。

第二轮再提取 ExecutionManager。这样可以在任何阶段安全回退，且不会把一次重构变成一个无法构建的长期分支。

---

## 18. 外部平台参考

- OpenAI：Developer Mode 与 MCP Apps 说明  
  https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt
- Apple：Service Management  
  https://developer.apple.com/documentation/servicemanagement/
- Apple：`NSXPCConnection` 连接 LaunchAgent/LaunchDaemon  
  https://developer.apple.com/documentation/foundation/nsxpcconnection/init(machservicename:options:)

平台功能和权限可能变化。实施到真实 ChatGPT/Tunnel 阶段时必须重新核对官方文档，不以本文日期的界面名称或套餐权限作为永久事实。
