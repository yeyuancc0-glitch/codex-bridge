# Codex Bridge Project Guide

## 项目长期目标

- 构建一个 GitHub 开源、个人自托管、零开发者云服务器的原生 macOS 应用。
- 让 ChatGPT 网页版通过 MCP 安全调用用户本机 Codex；ChatGPT 负责形成任务契约，Codex 负责执行，默认推荐 Luna（但允许用户选择其他可用模型）负责只读监督，Bridge 负责权限、状态、审批、连接和证据。
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
- SQLite 持久化使用 GRDB；日志使用 swift-log；密钥只进入 Keychain。
- Git 与验证命令使用 `Process` 和 argv 数组，不拼接 Shell 字符串。
- 2026-08-12 本机事实：外置完整 Xcode 27.0 Beta 5（build `27A5237l`）位于 `/Volumes/fanch/Applications/Xcode-beta.app`，签名、License、First Launch 与全部 27.0 SDK 检查通过；Codex CLI 为 `0.147.0-alpha.6.5`，Git 2.54.0。
- 系统级 `xcode-select` 仍指向 Command Line Tools，因为切换需要用户管理员密码。项目命令必须通过 `Scripts/with-xcode.sh` 运行；非默认 Xcode 位置使用 `CODEX_BRIDGE_XCODE_DEVELOPER_DIR` 指向已验证的 Developer 目录。

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
- 任务投影快照只是事件日志的原子派生缓存：与事件序号 CAS 在同一 SQLite 事务推进；缺失或落后的快照必须从有界事件页重建，不能截断历史来猜测状态。
- 项目访问唯一来源是 `ProjectRegistry`；MCP 只接受不可猜测的 `project_id` 和相对路径。
- 所有 app-server SDK/Schema 差异封装在 Codex RPC 适配层。
- 所有 MCP SDK 类型封装在 MCP 适配层，不能渗入领域层。
- Execution 与 Supervisor 请求、事件、生命周期和失败恢复完全隔离。
- Supervisor 只读、无网络、`approvalPolicy = never`，不能修改项目或批准风险操作。
- 当前 app-server `thread/start` / `turn/start` 没有可验证的 core-tools 禁用字段；`readOnly` 不能证明 Luna 无法读取项目或用户文件。Production Supervisor 必须保持 unavailable，直到 evidence-only 进程隔离经真实恶意读取回归证明有效，不能只靠空 cwd 或提示词宣称安全。
- Policy Engine 是安全边界；模型判断只是证据，不能扩大权限。
- 任务事件追加写入，当前状态从事件归约；禁止修改历史事件。
- `TaskPhase` 与 `TaskActivity` 分离：监督/纠偏是 activity，不伪造生命周期变化；恢复使用 `recovering/unknown`，完成必须已有最终报告。
- interrupt/suspend 先记录意图，只有 app-server 的 turn 停止事实才能进入对应终态。
- 任何会改变 Codex 状态的审批、停止或纠偏操作都先追加持久化意图；只有 RPC 成功或 app-server 事件确认后才能记录完成事实。Suspended 事实与旧 generation 两把锁的释放必须在同一 SQLite 事务提交；立即 resume 必须等待旧 worker 退出或排入 successor start，再重新原子获取两把锁并启动新 turn generation。
- `EventStore` 通过事件序号 CAS 追加；提交幂等键是 `(origin, key)`，同指纹复用、异指纹拒绝；Thread 与工作树两把锁必须在同一 SQLite 事务获取。
- 所有内部 SQLite migrator 在已有库存在已知待迁移版本时，必须先发布组件隔离、`0600`、SQLite online backup 生成的一致性备份；新库与已是当前版本的库跳过，备份边界或完整性失败必须在任何 schema mutation 前停止。
- 新任务的 submission 与首个领域事件和幂等 claim 在同一 SQLite 事务提交，任何读者都不能观察到只有 claim、没有初始投影的半初始化任务。
- 生产 Execution 启动必须先准备 app-server 会话并获得精确 Thread identity，再用同一事件事务把 provisional Thread 锁替换为精确 Thread 锁并持久化启动意图；只有事务成功后才能调用 `turn/start`。
- Git、验证、Supervisor 与最终报告证据必须绑定同一个 `task + project + thread + turn + generation + event sequence` 作用域；旧 generation 证据不得完成新 generation，最终编排阶段必须可幂等恢复。
- 生产任务完成只能走 `BridgePipeline.PipelineFinalizer`：必须解码并核对 typed Git/Verification/Supervisor `final_accept` 证据与报告 SHA-256；`TaskCoordinator.complete` 仅保留低层兼容，不得由 App/MCP 直接调用。
- 生产验证命令授权使用持久化一次性 capability，绑定 task/project/command/root device+inode/generation/expiry 并在启动进程前原子消费；旧 `.localUserApproved` 仅为直接本机兼容 API，不得接入任务流水线。
- Codex 审批响应使用持久化 barrier：同一事务先把 ticket 从 pending CAS 预留为 resolving 并记录意图，再发送精确关联响应；终态通知暂存到 Approved/Denied 事实写入完成后才归约。未决 ticket 禁止进入 verifying；运行期协议或持久化失败必须先按精确 generation 终止并等待会话退出，确认停止后才可失败任务并释放锁。
- 生产任务流水线在持久化 turn 启动意图后、真正启动 app-server turn 前保存 Git baseline；最终化必须绑定精确 task/thread/turn/generation/event sequence。应用重启时按 Finalizer → Pipeline preflight → 通用任务恢复的顺序处理，避免把可继续完成的 verifying 任务降为 unknown。
- 启动与唤醒恢复只允许用只读 `thread/read(includeTurns: true)` 对账：精确绑定的 completed/interrupted/failed 可归约，仍由当前 Runtime 持有的 session 可继续观察；仅看到 inProgress 但无法重接事件流时必须进入 unknown 并保留锁，严禁用 `thread/resume` 或新 `turn/start` 伪造恢复。unknown 只能由本机用户明确标记为 suspended，且恢复事实与两把锁释放必须在同一事务提交；该动作不恢复旧进程、不启动新 Turn。
- 生产验证命令只能消费绑定 task/project/root/command/generation 的一次性本机授权句柄；缺少句柄时只记录明确的 unavailable 证据，禁止调用兼容用的直接批准接口或伪造 passed。
- 原生本机任务使用独立 `macos.app` origin，只允许 read-only、无网络、动态目录中精确存在的 execution model/effort 和用户选择的 Supervisor model/effort；默认首选 `gpt-5.6-luna`，不可用时不静默替换已选择模型；existing Thread 在 claim 前必须重新核对项目 cwd。Thread/history/model 目录只作不持久化的有界投影，所有 catalog 操作共享单飞门并受整体 deadline 约束。
- 项目移除或离线卷身份重绑与新任务提交/暂停任务恢复必须共享 project mutation gate；变更期间禁止新的 admission，存在活动任务时拒绝变更。移除只在同一仓库事务删除 Thread 绑定、注册根和项目配置；身份重绑只接受用户重新选择的同一规范化路径、仅支持无 worktree 的单根项目，并在同一事务替换 root identity、清除陈旧 Thread 绑定。两者都绝不移动或删除本机项目文件。
- Codex 账号限额只在用户刷新概览时通过隔离 catalog 读取，不在启动或任务事件上轮询；应用层仅投影校验后的百分比、重置时间与触达状态，禁止把服务端自由文本带入 UI。
- App 生命周期只把 `taskChanges()` 当唤醒提示，正确性来自 EventStore 的全局持久 change cursor；终态通知用 `taskID + event sequence + terminal kind` 的稳定标识和 SQLite reservation 去重，通知开关与 consumer cursor 边界必须在同一 SQLite 事务提交，关闭时不重放历史。
- 手动暂停接收是独立于睡眠/停止的持久偏好：由 `DesktopTaskLifecycleCoordinator` 写入 EventStore，再驱动 `DesktopRemoteAdmissionGate` 排空已获 lease 的请求；它只关闭新的远程提交，不中断本地任务，连接替换和唤醒复核成功后仍保持暂停，恢复操作也不能绕过当前 transport 健康状态。
- Secure Tunnel helper 在已就绪后意外退出时，只重建 helper，不停止本地 MCP 或本地任务；使用有界 `1s/2s/4s` 退避且每次重新执行完整 helper 信任与严格 ready 校验。认证/授权诊断立即停止自动重试，耗尽三次后保持远程 admission 关闭并要求本机用户处理；Transport stop/shutdown 必须取消并等待在途重启。
- 终态通知的点击路由只携带版本化、有界且通过出站安全检查的 task identity；App 未启动或任务快照未就绪时由 Presentation 保留单个待选任务，加载后只选择精确匹配项，用户手动选择会取消旧路由。
- `willSleep` 必须同步关闭新的远程提交并等待已获得 lease 的请求排空；只有对应 sleep epoch 的 `didWake` 才能在任务事实刷新和当前 Transport 严格复核后重新开放。孤立或重复 wake 事件必须幂等忽略，不能重测健康链路或把已开放 admission 关回休眠；Transport 复核也不能冒充完整的 app-server/Thread/Git 恢复。

## 安全不变量

- 本地 MCP 仅回环监听，并使用 Keychain 中的 256-bit 随机认证 Secret；Inspector/本机开发可用秘密路径，Tunnel 生产链路必须用固定 `/mcp` 路径与 fd-backed 静态请求头。
- MCP 不接受任意绝对路径，不提供万能 Shell 工具。
- MCP 的所有自由文本出站前统一经过 `OutboundContentSecurity`；绝对路径检测不能依赖空白前缀，必须覆盖 `file:///Users/...`、Markdown `](/Volumes/...)` 等嵌入边界。
- app-server 返回并将持久化的 Thread/Turn ID 也必须执行长度、控制字符和 `OutboundContentSecurity` 校验；Application 出站再次 fail-closed，不能把标识符当成天然安全文本。
- 相对路径必须标准化、解析符号链接后再次验证仍在注册根目录内；读取时从根目录描述符逐级 `openat + O_NOFOLLOW`，并复核根与目标文件的 device/inode，防止校验后替换竞态。
- 默认拒绝 `.env*`、私钥、Keychain、浏览器 Cookie、Codex auth 等敏感路径。
- Runtime Key 只用于 Tunnel，永不传给 Codex/Luna，永不写日志或支持包。
- Supervisor 认证只由 Codex app-server 写入隔离 HOME；Bridge 永不读取、复制、解析或记录 `auth.json`、Cookie、Token、登录 URL 或验证码。每个隔离 HOME 需要独立的官方登录事实，不能声称跨 HOME 复用登录。
- 支持包只能从明确允许的有界结构化事实生成；不导出 Endpoint、项目/任务标识、原始输出、源文件或凭证。导出 JSON 上限 1 MiB，以规范化目录描述符逐级无跟随打开，再用 `0600` 临时文件原子替换。
- App 启动必须持有私有 0700 数据根目录 inode 和 0600 lock file 的跨进程租约；退出先停止并排空全部本地 MCP 请求，再关闭 lifecycle、Connection、Supervisor 与 Execution，旧 wake 或连接替换不得重新开放提交。
- 网络默认关闭；包安装、网络、Git 写和项目外访问要求本机确认。
- 高风险删除、系统写、凭证读取、生产迁移直接拒绝。
- 同一 Thread 同时最多一个 Bridge active turn；写任务持有项目工作树锁。
- 幂等键必须阻止重复任务、重复 Thread、重复 turn 和重复审批弹窗。
- 远程 steer、suspend、interrupt 的 Supervisor action 必须在 `TaskCoordinator` 当前 binding 与事件序号 CAS 的同一持久化意图边界内校验，不能在 Application actor 预检后调用无条件 mutation；durable action 必须持久化 task event sequence，先从 `pending` 进入 `ambiguous`，仅在 CAS 意图和 Runtime RPC 都成功后标记 `applied`，不确定失败禁止自动重试。
- Supervisor checkpoint sequence 与 task event sequence 是两个独立字段；action 创建必须由当前 task projection 显式传入事件序号，不能从 checkpoint position 推导。

## 项目结构记忆

- `App/`：应用入口、窗口、菜单栏、资源与 Entitlements。
- `CodexBridge.xcodeproj` / `BridgeAppShell`：真实 macOS App target 与组合根；主窗口和菜单栏共享同一个 `BridgeDesktopRuntime`。Application Support 数据目录固定 0700、数据库文件固定 0600，退出必须等待 bootstrap 和在途本机操作收口；首次引导只持久化非秘密状态，所有连接 Secret 只进 Keychain，已完成的连接若恢复自检失败必须退回连接测试步骤。
- `UI/`：Onboarding、Overview、Projects、Threads、Tasks、Approvals、Connections、Logs、Settings 与共享原生组件。
- `Packages/BridgeCore/Sources/BridgeDomain`：值对象、任务状态机、错误和协议。
- `BridgeCodexRPC`：Codex 进程、JSON-RPC、能力协商和版本兼容。
- `BridgePersistence`：SQLite/GRDB 事件存储与迁移。
- `BridgeProjects` / `BridgeGit` / `BridgeSecurity`：项目白名单、Git 证据与确定性策略。
- `BridgeMCP`：本地 Streamable HTTP MCP 与工具适配。
- `BridgeSupervisor`：检查点、结构化判断、防循环与纠偏；`EvidenceOnlyProcessBoundary` 用 macOS Seatbelt 将可选 Supervisor app-server 限制在每任务隔离 HOME，并拒绝 HOME 之外的 `/Users` 与注册项目根读写。认证只允许用户通过该 HOME 的官方 `account/login/start` + 系统浏览器 + `account/login/completed` + `account/read` 完成，认证进程仅允许出站网络，随后必须停止并以完全禁网配置重启 review；当前仅完成 fixture 回归，未因认证配置缺口打开生产 admission。
- `BridgeRuntime`：每任务隔离的 Execution app-server 会话、审批关联、generation、steer/interrupt 和终态观察。
- `BridgeRepositories`：项目配置、Thread 绑定和最终报告的 GRDB 持久仓库。
- `BridgeApplication`：把项目、Thread、模型、任务、报告和文件能力组合成 MCP/Application API；对外 DTO 必须脱敏且不得暴露规范化绝对根路径。
- `BridgeFiles`：以项目根目录描述符为边界的受限文件读取与搜索；Git index 只作有界候选来源，不启动 Git 或项目代码。
- `BridgeVerification`：仅执行项目已登记且经本机确认的验证命令，结果只保存有界结构化摘要和哈希，不返回原始进程输出。
- `BridgePresentation` / `BridgeAppModel`：原生 SwiftUI 纯展示层与 `@MainActor` 应用投影/动作路由；基础设施状态只能单向进入快照，审批授权能力缺失或不匹配时必须退化为只能拒绝。
- `BridgeTunnel`：官方 helper 校验、启动、健康和恢复。
- `docs/CHATGPT_DEVELOPER_MODE.md`：ChatGPT Developer Mode、Secure Tunnel/Manual HTTPS 的人工接入与生产验收顺序；凭证只由用户在本机输入，不进入仓库。
- `BridgeReporting`：结构化最终报告和脱敏支持包。
- `BridgePipeline`：按不可变执行作用域持久化 Git、验证、Supervisor 与报告元数据，并维护可恢复的 finalization saga；普通查询不返回原始证据 payload。
- Retention 由 `EventStore` 的 policy/CAS/job 记录和 `DesktopTaskRetentionCoordinator` 驱动，是有界、可恢复的 saga：必须先把终态 metadata 变为 archive-authoritative，再按活动锁、通知 lease、验证授权和外部清理结果推进 pipeline、supervision、事件历史与 payload 清理，metadata purge 只能最后执行；pipeline patch physical release 使用持久 manifest，supervision 删除终态记录后必须恢复 append-only triggers。
- `Prototypes/AppServerProbe`：阶段 0 可行性验证；稳定后能力进入 `BridgeCodexRPC`。
- `Tests/`：真实集成、安全、UI 和隔离 Fixture；任务结束清理无长期价值的产物。
- `UITests/`：Xcode 原生 App 自动化与无障碍验收；必须使用隔离用户目录，不能读取真实 Application Support 数据。

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
- 动态读取模型和 reasoning effort；默认推荐 Luna，但用户可选择目录中的其他模型；不可用用户选择的模型时返回明确失败，绝不静默换模型。
- `submit_task` 异步返回，任务通过游标查询；ChatGPT 对话不能被本机主动唤醒。
- V1 默认原工作区并保存 Git baseline；新 Thread 可实验性使用 worktree，绝不自动清理。
- 设计交付模式由用户授权代理决定：采用“完成设计包后直接实现”，不生成页面参考图。

## 实施顺序

1. 真实验证 Swift 对当前 Codex app-server 的 initialize、模型、线程、turn、steer、interrupt 和 Supervisor 可行性。
2. 建立原生应用骨架、持久化、日志、Keychain、系统检测和项目注册。
3. 完成本地只读 MCP 闭环，再接 Tunnel。
4. 完成任务执行、安全审批与结构化报告。
5. 完成默认推荐 Luna 的 Supervisor、恢复、完整 UI、通知、打包与发布。

## 常用命令

```bash
Scripts/with-xcode.sh swift build --package-path Packages/BridgeCore
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeUITests test
Scripts/with-xcode.sh swift run --package-path Packages/BridgeCore codex-rpc-fixture basic
Scripts/with-xcode.sh swift run --package-path Prototypes/AppServerProbe app-server-probe --help
Scripts/verify-mcp-inspector.sh
Scripts/build-tunnel-helper.sh OUTPUT_DIRECTORY
Scripts/verify-tunnel-helper.sh HELPER_DIRECTORY TRUSTED_UNSIGNED_SHA256
Scripts/test-tunnel-helper-config.sh
Scripts/build-release-candidate.sh OUTPUT_DIRECTORY HELPER_DIRECTORY TRUSTED_UNSIGNED_SHA256
codex app-server generate-json-schema --out DIR
```

- `build-release-candidate.sh` 只生成明确标记为 unsigned 的 Universal 2 ZIP/DMG/SBOM/checksum 候选；Developer ID、notarytool、staple 与干净 Mac 验收仍是独立凭证门禁，流程见 `docs/RELEASE.md`。

## 常见坑与注意事项

- `codex app-server` 是实验接口；只信当前本机 Schema、能力协商与真实回归，不能硬编码记忆中的字段。
- 当前 app-server wire 契约与方案的必要修正记录在 `docs/CODEX_PROTOCOL_COMPATIBILITY.md`；尤其注意无 `jsonrpc` 字段、Thread/Turn 两套 sandbox 表达、开放 reasoning effort 和多种审批响应。
- `turn/start` 响应只表示请求已受理；必须等待匹配的 `turn/started` 事件后才能 steer 或 interrupt，不能把请求响应当作 active-turn 事实。
- EventStore 持久事件 kind 使用 `task.<domainKind>` 前缀；生命周期消费者必须匹配真实存储值。变更日志迁移只记录迁移后的事件，禁止为通知同步回填全部历史事件导致启动无界扫描。
- stdout 是 JSON-RPC 协议通道；任何非 JSON 污染都必须检测，诊断只读 stderr。
- 进程退出必须原子取消全部等待请求，避免 continuation 泄漏或重复恢复。
- `CodexAppServerClient` 是一次性进程会话；停止、初始化失败或协议失败后由上层创建新实例，不能复用已终止的 dispatcher/event stream。
- app-server stdout 与事件队列都必须有硬上限；审批/服务端请求不得静默丢弃，拥塞时终止会话并进入恢复。
- 每个 app-server 会话只能有一个事件消费 actor；多个 `AsyncStream` iterator 会分流而不是广播，UI/执行器/审批必须订阅该 actor 归一化后的事件。
- Xcode 27 下不要在 detached task 中用阻塞式 `FileHandle.read(upToCount:)` 驱动管道；使用 `readabilityHandler` 接入有界 `AsyncStream`，再由单消费者解析。
- `.github/workflows/ci.yml` 在 GitHub 的 ARM64 `xcode-27` public-preview runner 上执行无凭证门禁；只证明源码、协议和 unsigned App 兼容，不读取 Runtime Key/账号/签名材料，也不能替代 Developer ID、公证、真实 Tunnel 或干净 Mac 验收。macOS XCUITest 固定精确 arm64 destination 且关闭并行执行，避免 Automation 服务争用造成假失败。
- Thread 只能按规范化 cwd/worktree 精确绑定，不能按标题或“最近使用”猜测。
- 自动审批不能信任审批请求里的 shell 字符串或 best-effort `commandActions`；必须用 `threadId + turnId + itemId/approvalId` 关联已持久化的权威执行事件，缺少规范化 argv、路径或大小时一律不自动批准。
- 三类 app-server 审批请求必须使用有界强类型模型解码，并与同一 `item/started` 的 immutable identity、时间和 `inProgress` 状态精确关联；审批证据与 pending 事实原子持久化。命令字符串与 `commandActions` 只作为明确标注的展示证据，未形成规范化权威操作前 UI 只能拒绝。
- file-change 证据可保存最多 100 项、2 MiB 的完整规范化 manifest、每项 diff 摘要与注册根 device/inode，但不保存 raw diff；单 manifest 编码上限 128 KiB，单任务 pending 审批证据总编码上限 256 KiB。当前 app-server 最终仍按 pathname 写入，Bridge 无法把检查与变更原子绑定，因此 file-change 也必须保持 deny-only；permissions 的 turn/session 扩权同样不得包装成“仅允许一次”。
- 只读命令自动放行必须使用固定系统可执行文件路径，不能只看 basename 或未解析的 PATH；配置验证命令仍先经过系统硬拒绝与 wrapper 检查。
- dirty 工作区中任务修改与用户修改可能混合；必须保存 baseline 并在报告中诚实标注。
- Git 证据命令只能用固定 `/usr/bin/git`、最小环境和已打开目录 fd 作为 cwd；仓库本地 filter、fsmonitor、include、textconv/command 或任何 `filter` attribute 都必须在执行 status/diff 前 fail-closed，防止证据收集执行项目代码。
- Tunnel 断线不能中断本地任务，但断线期间不得接受新的远程任务。
- 远程 admission 的 `closed`、`asleep`、`revalidating` 和 `stopping` 状态必须分离：停止或失败唤醒复核后保持 `closed`，只有新的健康配置完成才重新开放；不能复用“成功后重开”的 replacement transition 完成停止。
- AppShell 的 `DesktopConnectionRuntime` 是 Local、Manual HTTPS 与 Secure Tunnel 三种传输的唯一生命周期和健康状态源；切换模式必须先停止旧链路，本机 MCP 就绪不能被投影为 ChatGPT 远程就绪。Manual HTTPS 只接受无重定向的强认证 `/mcp` 地址，并使用有界请求、响应和超时。
- `tunnel-client` 必须使用调用方预建的 0700 私有根、dirfd/inode 绑定的每次运行目录、Unix-domain health/admin socket 与最小化子进程环境。禁止把配置交给可替换的 pathname；非秘密配置使用固定 argv，Runtime Key 经 fd3、MCP 静态认证头经 fd4。官方 v0.0.11 不支持把 MCP URL 写成 `file:`，所以只传非秘密 `http://127.0.0.1:<port>/mcp`。`/readyz` 只证明本地 MCP 就绪，只有 health peer PID 匹配、严格 ready 且 control-plane poll 成功并新鲜时才可显示 Tunnel 已连接。
- Tunnel helper 必须先按外部可信的签名后 SHA-256 校验打开的同一 fd，再以 suspended 状态 spawn；只有动态 SecCode 通过宿主 Team requirement 且 CDHash 与静态 fd 身份相同时才恢复和写入秘密。签名前 supply manifest 不能充当运行时信任根。
- Xcode 的 `Stage Tunnel Helper` phase 对普通开发构建是可选的；Release 候选必须显式提供独立可信的 unsigned helper SHA-256。Helper 先签名/暂存，再计算 App 内 post-stage 摘要，最后才签外层 App。
- Swift MCP SDK 0.12.1 不提供可直接导入的生产 HTTP listener；`BridgeMCP` 必须自建仅绑定 `127.0.0.1` 的 NIO 外层，负责秘密路径或 Tunnel 认证头、请求/会话/结果上限、超时、背压和清理。SDK 的 stateful stored events 与多处 AsyncStream 无界，须按 `docs/MCP_SWIFT_SDK_INTEGRATION.md` 轮换会话。
- `BridgeMCP` 无任务后端时保持五个只读工具兼容；注入任务后端后追加七个任务查询/提交/steer/interrupt 工具，但不远程公开 Codex 审批。每个 HTTP session 独占一个 strict SDK Server，全局/单 session 工具并发上限为 8/2，完整双形态结果上限 200 KiB，响应最迟 25 秒关闭并回收 session。新增工具不能绕过这些统一边界。
- `BridgeMCP` 注入项目操作后再追加 `get_project`、受限文件 search/read 与 `open_in_codex`；任务和项目后端同时启用时共 16 个工具。项目工具仍只接受 `project_id` 与相对路径，打开 Codex 前必须重新核对 Thread cwd 属于该项目。
- MCP HTTP admission 必须用幂等 request lease 转移所有权：未收到 request end 的断连由 channel 释放，进入业务 Task 后只由 Task 释放；App shutdown 关闭 listener 后必须等待全部业务 lease 排空，不能用裸计数布尔或 `responseTask == nil` 推断所有权。
- 原生 App 生产组合必须注入完整 16 工具；Secure Tunnel 的 `submit_task` 每次调用都直接核对当前 generation 的严格 Tunnel 健康，不能依赖轮询缓存，本机 Path Secret 模式仅用于本机开发与 Inspector。
- UI 的任务刷新由 `EventStore.taskChanges()` 提供提交后的有界提示，但任务事实仍只从事件存储重新投影；本机任务确认不得改写远端提交的 model/effort，缺少权威操作证据的 Codex 审批只能拒绝。
- 登录时启动只使用 `SMAppService.mainApp`，系统 `status` 是唯一事实源；`requiresApproval` 必须明确提示用户去系统设置批准，测试通过系统适配器注入状态，禁止修改开发机真实登录项。
- 原生任务证据必须由用户选中任务后按需读取，不得在全局任务刷新时对历史终态任务批量解码；缓存必须绑定 `task + binding generation + event sequence + report reference` 并保持有界，校验失败明确显示 unavailable，禁止伪装为空证据。
- 最终 Git patch 使用 0700/0600 私有持久存储、digest 绑定、有界 LRU、跨实例文件锁和提交标记裁剪；首次访问形成受总容量约束的验证快照，MCP 分页必须按真实双形态 200 KiB 编码预算和 UTF-8 边界缩页。
- 本地验证器不是 OS sandbox。本机明确批准验证命令后，项目程序或工具链插件仍可能自行读取项目外文件或联网；已知网络命令和 Shell wrapper 必须硬拒绝，发布前若要声称强隔离必须另接真正的进程沙箱。
- Execution 与 Supervisor 都必须动态核对精确 model/effort；默认 Luna 或用户选择的其他模型不可用时返回明确失败，绝不静默换模型。Supervisor 固定只读、无网络、`approvalPolicy = never`，收到任何服务端审批请求立即 fail-closed。
- Supervisor 的 checkpoint 出站过滤只约束提示内容，不约束同一 app-server 进程自行读取文件。没有 OS 级 evidence-only 隔离或经实测的 no-tools 协议能力时，终局复核和持续 checkpoint 都不得在 production 启动进程；状态必须诚实显示 unavailable。
- 官方 MCP Inspector 验收固定使用 `@modelcontextprotocol/inspector@2.1.0` 和测试专用随机 Path Secret；错误调用必须分别核验 stdout 完整结果、stderr `tool_is_error` 与退出码 5。Inspector 是 one-shot，不能把 fresh connection 称为 same-session reconnect，也不能代替协议取消测试。
- 数据根目录 inode 的 advisory lock 只能绑定已打开对象；若发布威胁模型要求抵抗同一 UID 主动 rename 并重建整个数据根，必须另接稳定父锚或 LaunchServices/launchd 单实例机制，不能把当前目录锁描述为已覆盖该攻击。
- 不带包装脚本的 `/usr/bin/xcodebuild` 会误用 Command Line Tools；看到测试宏、XCTest 或 SDK 缺失时先检查 `DEVELOPER_DIR`，不要重复安装 Xcode。

## 维护检查

- 每次任务结束前检查是否出现新的长期命令、架构决策、兼容坑或过时事实。
- 仅把长期有效且不敏感的信息写入本文件；一次性进度放到 issue/提交记录或阶段台账。
- 超过 250 行时整理、核对并压缩。
