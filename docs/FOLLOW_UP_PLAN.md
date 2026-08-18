# Codex Bridge 后续完成与发布计划

> **已冻结的旧路线。** 本计划面向旧控制平面的生产硬化与公开发布，不再定义当前轻量 V1 的实施顺序。新的权威计划为 [`V1_LIGHTWEIGHT_REFACTOR_PLAN.md`](./V1_LIGHTWEIGHT_REFACTOR_PLAN.md)。除非新 Service 闭环已经完成且用户明确恢复某项能力，否则不要继续执行本文的 Saga、Evidence、Retention 或多库硬化任务。

> 版本：2026-08-16  
> 基线：`main`，`f3df2ff`（Luna 目录语义修正）；前一项备份核心提交为 `ae598a0`  
> 目标：在不削弱现有 fail-closed 安全边界的前提下，完成 V1 的可恢复性、真实 Supervisor、外部 MCP 接入和公开发布验收。

## 1. 当前基线与完成度

### 1.1 已确认完成

- 原生 SwiftUI/AppKit macOS Bridge 主体、AppShell、菜单栏和主要页面已经存在。
- 本地 MCP、Manual HTTPS、Secure MCP Tunnel 三种传输的组合生命周期和远程 admission gate 已实现。
- Codex app-server 的 initialize、动态 `model/list`、Thread/Turn、steer、interrupt、审批关联、事件存储、恢复和幂等边界已实现并有本机测试证据。
- 项目白名单、相对路径读取、敏感路径拒绝、Git 证据、验证授权、结构化报告和支持包边界已实现。
- Supervisor 的结构化协议、反循环、出站过滤、Seatbelt evidence-only fixture 和“生产不可用时拒绝提交”已实现。
- Luna 只是当前模型目录中的默认推荐，不是内置模型；`model/list` 是唯一事实源，用户可选择其他当前可用模型，选定模型失效时明确失败且不静默替换。
- `DesktopBackupPackage` 已实现三份持久 SQLite 文件的 allowlist、manifest、SHA-256、大小上限、`0700/0600`、owner/regular-file/single-link、`O_NOFOLLOW` 和原子发布校验。
- 已记录的本机验证包括 Swift Package 全量测试、严格 `swift-format`、arm64 App 构建、unsigned Universal 2 候选、Tunnel helper 供应校验、Inspector 合同和原生无障碍 smoke test。

### 1.2 尚未达到公开发布条件

当前仓库是“核心代码基本完工、生产验收未闭环”的状态。完成度仅作排程参考，不是安全或质量指标：

| 维度 | 估算 | 说明 |
|---|---:|---|
| 核心架构与本机代码 | 约 90% | 主要模块和安全边界已落地；仍有备份恢复 UI、多根卷身份、连续 checkpoint 等缺口。 |
| 自动化与本机证据 | 约 85% | 现有测试和 unsigned 构建证据较完整；credentialed live acceptance 仍缺失。 |
| 生产 Supervisor | 约 45% | 进程隔离 fixture 已有，真实隔离 HOME 登录和恶意回归尚未完成；`productionReviewAvailable` 必须保持 `false`。 |
| 外部 Tunnel/ChatGPT | 约 35% | fake helper/本地 MCP 已验收，真实 Restricted Runtime Key、Tunnel ID 和 ChatGPT Developer Mode 尚未验收。 |
| 签名与发布 | 约 35% | 只有 unsigned Universal 2 候选；Developer ID、公证、staple、Gatekeeper 和干净 Mac 仍未完成。 |
| V1 发布完成度（综合估算） | 约 75%--80% | 可以继续收尾，不代表已经可以公开分发。 |

### 1.3 事实来源

- 阶段状态以 [`PHASE_LEDGER.md`](PHASE_LEDGER.md) 为准；`blocked` 只表示某个 artifact 的门禁未满足，不等于整体任务失败。
- 协议和 Supervisor 约束以 [`CODEX_PROTOCOL_COMPATIBILITY.md`](CODEX_PROTOCOL_COMPATIBILITY.md) 与 [`AGENTS.md`](../AGENTS.md) 为准。
- 外部接入顺序以 [`CHATGPT_DEVELOPER_MODE.md`](CHATGPT_DEVELOPER_MODE.md) 和 [`TUNNEL_CLIENT_INTEGRATION.md`](TUNNEL_CLIENT_INTEGRATION.md) 为准。
- 发布命令和凭证边界以 [`RELEASE.md`](RELEASE.md) 为准。

## 2. 总体执行规则

1. 每个阶段都要同时记录：代码变更、测试命令、环境、时间、结果、产物摘要和未决风险。
2. 只有真实可核验的事实才能打开下一道门；fixture、提示词、空工作目录或自然语言承诺不能替代进程隔离和外部验收。
3. 任何认证、Runtime Key、Tunnel ID、Keychain 内容、`auth.json`、Cookie、SSH Key、临时 capability 和用户目录凭证都不进入仓库、日志、支持包或计划文件。
4. 发生协议异常、凭证不完整、root/device/inode 漂移、证据 scope 不匹配或恢复状态不确定时，保持 `unavailable`/`unknown`/`closed`，不猜测、不 fallback、不伪造 passed。
5. 完成一个可独立验证的代码功能后再提交独立 Git commit；本计划文件本次只作工作树文档，不自动 commit、push 或执行生产迁移。
6. 每轮完成后更新 [`PHASE_LEDGER.md`](PHASE_LEDGER.md)，但不把一次性计划、账号状态或秘密写入长期项目记忆。

## 3. 优先级与依赖总览

```text
P0 备份/恢复闭环 ───────────────┐
                               ├─> P1 真实 Supervisor ──> P1 ChatGPT/Tunnel 外部验收
本机回归与 hosted CI ───────────┘                         │
                                                         └─> P1 签名/公证/干净 Mac 发布
P2 多根卷、恢复、证据、UI 矩阵可并行收尾 ────────────────────────┘
```

- **P0**：不完成就不能把本机数据保护或任务监督描述为完整产品能力。
- **P1**：不完成就不能打开生产远程提交，也不能公开分发。
- **P2**：不阻止本机开发继续，但应在稳定发布前完成，或明确写入 release notes 的 accepted omission。

## 4. P0：备份与恢复闭环

### 4.1 目标

把现有“只验证调用方快照”的 `DesktopBackupPackage` 接成真正可用的用户流程：从在线 SQLite 生成一致快照，导出到用户选择的位置；恢复时先验证并 staged，完整停止 App 后才原子替换，失败时保留当前数据。

### 4.2 实施顺序

1. **一致性快照适配器**
   - 在 `BridgePersistence`/`BridgeAppShell` 增加基于 SQLite online backup 的 snapshot provider。
   - 三份固定文件必须对应当前 allowlist：`application.sqlite`、`supervision-ledger.sqlite`、`task-events.sqlite`。
   - 每个源库用在线备份 API 生成临时 `0600` 快照；不能通过普通文件复制声称一致性。
   - 记录源 schema 版本、快照大小、SHA-256 和创建时间，但不记录原始事件、项目根、Thread ID 或路径。
2. **导出 UI 与 admission gate**
   - 在 Settings 增加 Export Backup 操作，使用系统保存面板，目标必须由用户明确选择。
   - 导出前读取活动任务、持久化锁、pending approval 和在途本机请求；只要存在活动任务或无法取得稳定快照，拒绝导出并显示明确原因。
   - 导出调用现有 package validator，不复制 Supervisor HOME、Keychain、Runtime Key、transient capability、socket、临时目录或原始日志。
3. **staged restore 与 pending marker**
   - 选择备份包后先在私有 `0700` staging 根中执行 allowlist、manifest、权限、大小、digest、schema 和 `PRAGMA integrity_check`。
   - 创建带版本、目标数据根 device/inode、package digest 和恢复操作 ID 的 pending marker；marker 不含秘密。
   - 在真正停机前不触碰当前数据根，不删除或覆盖任何现有数据库。
4. **完整 shutdown 与原子替换**
   - 关闭新的远程 admission，排空 MCP lease，停止 Tunnel/lifecycle/Supervisor/Execution，等待全部 worker 和 app-server 进程退出。
   - 重新核对数据根 inode、活动任务和 lock owner；不满足条件则取消恢复并清理 staging。
   - 在私有父目录中使用已打开 dirfd、`O_NOFOLLOW`、fsync 和原子 rename/swap 完成替换；不要使用递归删除或未验证 pathname。
   - 旧数据移至同一私有父目录的保留目录，直到新库启动并通过完整性检查；成功后才按明确 retention 规则清理。
5. **启动前复核与失败保留**
   - 新库启动时先跑 schema/integrity/迁移前检查，再恢复项目、Thread、通知和 transport 的只读投影。
   - 任意步骤失败都保留原数据和 pending marker，状态显示 `restore failed`/`manual intervention required`，不得伪装成空库或自动覆盖旧库。
   - 恢复成功后清除 marker，写入不含敏感 payload 的恢复结果事实，并要求用户重新确认外部 Tunnel/登录状态。

### 4.3 必须测试的真实行为

- 在线写入期间快照三份数据库，恢复后每份都能通过 integrity/schema 检查，且跨库版本一致。
- 有活动任务、持有锁、pending approval、在途 MCP 请求或无法停止 worker 时，导出和恢复都拒绝。
- staged 包含 symlink、额外文件、错误权限、错误 manifest、篡改 digest、过大文件、错误 schema 时全部 fail-closed。
- 在 swap 前、swap 中、swap 后、重启前分别模拟崩溃；旧数据必须仍可启动，或明确保留在受保护的旧目录。
- 目标数据根和父目录发生 inode/权限漂移时停止，不跟随替换路径。
- 恢复包中不存在 Supervisor HOME、Keychain、Runtime Key、capability、socket、日志和项目源码。
- App 重启后远程 admission 默认关闭，只有当前 transport 与任务事实重新通过严格复核才能开放。

### 4.4 证据与停止条件

**输入**：当前三份 SQLite 路径、GRDB schema/migrator、用户选定的输出/输入 URL。  
**代码产出**：snapshot provider、restore coordinator、Settings action、pending marker schema/migration、恢复状态 projection。  
**建议命令**：

```bash
Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore
Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests
Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO
```

**停止条件**：任一恢复路径可能丢失当前数据、绕过活动任务 gate、跟随 symlink/pathname replacement、导出秘密或无法证明 online consistency 时，保持功能 unavailable，不进入 Supervisor 或发布阶段。

## 5. P0：Production Supervisor gate

### 5.1 目标

在不读取或复制 `auth.json` 的前提下，为每个任务建立隔离 HOME 的真实官方登录事实；认证完成后停止认证进程，再以同一 HOME、完全禁网、只读和 `approvalPolicy = never` 启动 Supervisor。只有真实恶意回归通过后才允许修改 `productionReviewAvailable`。

### 5.2 实施与验收顺序

1. 创建任务专属隔离 HOME，设置 `0700`、独立 inode 和生命周期清理边界。
2. 启动仅允许出站网络的认证 app-server；用户在系统浏览器完成官方 `account/login/start` 流程。
3. 只接受匹配的 `account/login/completed` 成功事实，并由同一隔离 HOME 的 `account/read` 核验；Bridge 不读取、解析或记录凭证文件。
4. 停止并回收认证进程，验证没有旧会话残留，然后以完全禁网配置重启 review app-server。
5. 动态执行 `initialize`、`model/list`、`thread/start`、`turn/start`；默认推荐目录中当前可用的 Luna，用户也可选择其他目录模型和 effort。所选模型不可用必须明确失败。
6. 用恶意 fixture/真实恶意项目验证 Supervisor 无法读取注册项目根之外的路径、用户目录、Keychain 或网络，不能写文件，不能批准任何 Codex 审批请求。
7. 验证 checkpoint、continuous projection、final `final_accept`、ambiguous action 和重启恢复都绑定精确 task/project/thread/turn/generation/event sequence。
8. 将完整证据保存为脱敏结构化摘要；在所有项通过前，保持 `productionReviewAvailable = false`，`submit_task` 继续 fail-closed。

### 5.3 证据清单

- 隔离 HOME 创建/权限/销毁日志（仅结构化状态和 hash，不含路径细节或凭证）。
- login completed 与 account read 的匹配 ID/时间窗口摘要。
- initialize/model/thread/turn 的 typed result 摘要和选定模型/effort。
- 恶意读、写、联网、审批请求的拒绝结果及进程退出状态。
- 断电/重启后未完成 review 的恢复结果；旧 generation 证据不能完成新 generation。
- `productionReviewAvailable` 变更前后的代码评审和回归记录。

**停止条件**：任何一步依赖提示词宣称只读、空 cwd、复制主 HOME、读取 `auth.json`、网络仍开放、审批可被 Supervisor 批准或 scope 无法核对时，继续保持 unavailable，禁止打开生产 admission。

## 6. P1：Secure Tunnel 与 ChatGPT Developer Mode 外部验收

### 6.1 前置输入（必须由用户在本机操作）

- 真实 Restricted Runtime Key：只通过 Bridge UI 写入 Keychain。
- 真实 Tunnel ID：通过 Bridge UI 配置，不出现在日志/支持包/计划文件。
- ChatGPT 账号的 Developer Mode / 自定义 MCP 应用权限。
- 如验证 Manual HTTPS，必须是用户自有、无重定向、强认证的 HTTPS `/mcp` 端点。

### 6.2 验收序列

1. 用 pinned tunnel-client v0.0.11 运行官方 helper doctor，核对 helper、Team/CDHash、fd3/fd4 secret delivery 和私有 runtime 目录。
2. 观察 `/healthz`、严格 `/readyz`、匹配 peer PID 和新鲜 `commands_poll_last_successful_timestamp_seconds`；只有全部满足才显示远程 admission 开放。
3. 在 ChatGPT Developer Mode 中连接同一 Tunnel，确认完整组合为 16 个工具：5 个只读、7 个任务、4 个项目/文件/导航；Bridge 不暴露 Codex 审批工具。
4. 先调用 `list_projects`、`list_threads`、`list_models`，再用真实项目 ID、真实模型 ID 和当前 catalog effort 提交最小只读任务。
5. 在本机完成确认后，用 `get_task` 观察事件序号、Supervisor 状态和终态；只有绑定同一 scope 的 `get_final_report` 才可宣称完成。
6. 断开 Tunnel：本地任务继续，新的远程提交拒绝；恢复 Tunnel：重新通过完整健康链路后才开放 admission。
7. 验证 helper 意外退出的 `1s/2s/4s` 重启、认证失败停止重试、应用 shutdown 排空 lease、sleep/wake 和 reconnect。
8. 对 Manual HTTPS 重复连接测试、无重定向检查、超时/大小上限和断线恢复；失败保持 `closed`，不能以本机 MCP ready 冒充远程 ready。

### 6.3 外部证据

保存连接时间、工具目录摘要、任务 scope 摘要、health/metrics 状态转换、断线/重连结果和用户确认结果；禁止保存 Runtime Key、Authorization、绝对项目路径或原始 Codex 输出。

**停止条件**：真实 `/metrics` 不新鲜、ChatGPT 目录不是 16 工具、任何远程路径/凭证泄露、断线停止本地任务、重连绕过健康检查或出现模型静默 fallback 时，不进入发布签名。

## 7. P1：签名、公证、Universal 2 与干净 Mac

### 7.1 产物链

1. 用户/发布环境准备 Developer ID Application、Hardened Runtime entitlement 和 release-owned `notarytool` Keychain profile；凭证不进仓库。
2. 重新构建并独立核验 pinned tunnel helper；先签 helper，再计算 post-sign SHA-256，最后签外层 App。
3. 用 `Scripts/build-release-candidate.sh` 的同等输入生成 arm64+x86_64 archive；signed release 的命名和警告不得继续标成 unsigned candidate。
4. 运行 `codesign --verify --deep --strict`，核对 App/helper Team ID、CDHash、entitlements、bundle 结构、SPDX SBOM 和依赖许可证。
5. 提交 DMG/ZIP 到 notarization，等待成功后 staple，重新计算发布 checksum。
6. 在至少一台 Apple Silicon 和一台 Intel 的干净 macOS 14+ 机器做 Gatekeeper、安装、首次启动、退出重启和卸载回归。

### 7.2 干净机验收矩阵

- 九步 onboarding、目录选择、Keychain 权限和连接测试。
- Local 只读任务、Manual HTTPS、Secure Tunnel（真实凭证由用户输入）。
- 活动任务、审批拒绝、暂停/恢复接收、sleep/wake、通知点击和 existing Thread recovery。
- 备份导出、恢复成功、恢复失败保留旧数据、无活动任务拒绝恢复。
- light/dark、VoiceOver、Reduced Motion、Increase Contrast 和窗口紧凑模式。
- Gatekeeper 无 quarantine bypass，签名 helper 与外层 App 身份一致。

**停止条件**：未签名、未公证、未 staple、Gatekeeper 失败、任一架构缺 slice、helper 重新下载或干净机无法启动时，不发布。

## 8. P2：本机剩余工程缺口

这些工作可与 P0/P1 的外部等待并行，但必须在稳定版本前完成，或逐项记录为明确的 accepted omission：

| 项目 | 代码/测试产出 | 完成判据 |
|---|---|---|
| 多根项目与 worktree 卷身份 | root device/inode/volume identity compensation、离线重绑和并发 admission 测试 | 卷移除/重挂后不误绑、不移动用户文件，活动任务期间拒绝变更。 |
| existing Thread credentialed recovery | 真实 `thread/read(includeTurns: true)` 对账、unknown 保锁、用户显式 suspended、恢复后 generation 证据测试 | 不调用 `thread/resume` 伪造旧 Turn；旧/新 generation 不能串证。 |
| finalization recovery | Finalizer → Pipeline preflight → 通用恢复的崩溃/重启测试 | 可幂等恢复 verifying/finalization，不重复报告或释放他人锁。 |
| continuous checkpoint projection | 有界投影、游标、重启重放和 UI loading/unknown 状态 | UI 只投影 EventStore 事实，不从 taskChanges 提示猜状态。 |
| native evidence workspace | Git/verification/Supervisor typed adapter 的分页、digest、scope 和 unavailable projection | 选中任务后按需读取；全局刷新不解码历史 raw payload。 |
| MCP 压力与取消 | slow reader、8/2 并发上限、25 秒响应上限、业务 lease 转移和 shutdown drain | 取消、断连和重启不泄漏 session/lease，不把半截结果当成功。 |
| 原生 UI 矩阵 | 各主要页面 light/dark/VoiceOver/Reduced Motion/Increase Contrast XCUITest 或截图证据 | 状态同时有文本和图标，紧凑窗口无重叠，Reduced Motion 无连续动画。 |
| hosted CI | 用户 push 后首个 `xcode-27` hosted run 记录 | hosted 结果与本机一致；不把 runner 通过当作签名/外部验收。 |

## 9. 阶段执行台账模板

每个阶段完成后在 issue/提交记录中使用以下字段，不把秘密写入文档：

```text
phase: P0-backup | P0-supervisor | P1-tunnel | P1-release | P2-...
owner: local-code | user-operated | release-owner
commit: <exact commit or N/A for external evidence>
environment: macOS version / Xcode / Codex CLI / architecture
commands: <exact commands>
result: passed | failed | unavailable | blocked
evidence: <typed summary, digest, artifact path outside repo>
scope: <task/project/thread/turn/generation/event sequence when applicable>
secrets_checked: none exported
next_gate: <single next gate>
```

失败记录必须保留原始状态的有界摘要和下一步，不得删除失败证据后重跑成“通过”。

## 10. 最终发布清单

只有下列项目全部满足，才将版本标记为可公开发布：

- [ ] 三份 SQLite 已通过 online backup 生成一致快照，Settings 导出和 staged restore 已通过崩溃/篡改/权限/活动任务回归。
- [ ] 真实隔离 HOME 官方登录完成；Supervisor 禁网、只读、恶意读写/联网/审批回归通过。
- [ ] `productionReviewAvailable` 仅在上述证据齐全后打开；Luna 仍是目录推荐而非内置模型，其他可用模型和失效模型路径均有测试。
- [ ] 真实 Restricted Runtime Key、Tunnel ID、helper doctor、ready、fresh metrics、断线重连和 ChatGPT Developer Mode 16 工具闭环通过。
- [ ] existing Thread recovery、continuous checkpoint、finalization recovery 和报告 scope 绑定通过。
- [ ] Developer ID 签名、Hardened Runtime、helper post-sign digest、公证、staple、checksum 和 SPDX SBOM 完成。
- [ ] Apple Silicon/Intel 干净 Mac Gatekeeper、安装/升级/卸载、权限、睡眠唤醒、通知和备份恢复通过。
- [ ] hosted `xcode-27` CI 有成功记录；README/UI 不再把 pre-release/unavailable 描述为 production ready。
- [ ] `PHASE_LEDGER.md`、`RELEASE.md` 和本计划状态已更新；无临时测试垃圾、凭证、Token、Cookie、Keychain 导出或无关文件。

## 11. 明确的未完成项与当前结论

### 未完成 / blocked

- 在线 SQLite snapshot 与用户备份/恢复 UI。
- 真实隔离 HOME 的 Supervisor 登录、禁网运行和恶意边界回归。
- 真实 Restricted Runtime Key、Tunnel ID、官方 metrics、ChatGPT Developer Mode 和 reconnect。
- Developer ID 签名、公证、staple、Universal 2 干净机 Gatekeeper。
- 多根卷身份补偿、credentialed existing Thread recovery、continuous checkpoint、丰富 native evidence adapter、完整 UI 辅助功能矩阵。

### 已完成 / 可继续使用

- 本机核心代码、fail-closed 策略、动态模型语义、Local MCP、fake Tunnel 生命周期、结构化报告和 unsigned Universal 2 构建路径。
- 无凭证环境下的自动化回归和安全边界验证可以继续运行，不需要读取任何用户秘密。

### 当前结论

本计划把“基本版本完成”与“公开发布完成”分开：当前可以继续进行本机开发和用户侧外部验收准备，但在 P0/P1 门禁全部通过前，产品必须保持 pre-release/unavailable 表述，远程生产提交和公开下载均不得宣称已完成。

