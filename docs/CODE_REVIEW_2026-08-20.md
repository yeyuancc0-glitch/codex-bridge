# Codex Bridge 代码审查与修复复核报告

- 初始审查日期：2026-08-20
- 初始审查基线：`main@b455404`
- 修复提交：`59d9c82 fix direct safety and service consistency gaps`
- 修复范围：原报告中的 5 个 P1 与 1 个 P2
- 当前判定：**Pass（本地工程验收）**

## 结论

原报告列出的 6 个问题已全部修复，并补充了能够复现原故障场景的长期回归测试。

本轮完成了完整 Swift 测试、严格格式检查、arm64 Debug App 构建、MCP Inspector 和 Tunnel helper 合同验证。共执行 29 个 XCTest bundle、929 tests，0 failures。

本地工程验收通过不等同于正式发布验收。真实 ChatGPT Developer Mode、受限 Runtime Key Tunnel、Developer ID 签名、Notary 与 Gatekeeper 仍需要用户凭证或外部平台参与，本报告未将这些边界标记为完成。

## 修复总览

| 原问题 | 级别 | 修复状态 | 核心修复 |
| --- | --- | --- | --- |
| Safe 命令可绕过项目根边界 | P1 | 已修复 | Swift/Xcode/npm 使用参数级 capability 校验，保留 Agent Reach/OpenCLI 合法链路 |
| read denied 后项目无法从 App 恢复 | P1 | 已修复 | 本机 managed 查询与远程 MCP readable 查询分离 |
| 有任务历史的项目无法删除 | P1 | 已修复 | SQLite 单事务全量检查活动任务并级联删除终态历史 |
| Git 提交与真实 index 同步不诚实 | P1 | 已修复 | 提交前锁定真实 index，基于快照同步提交树，并返回结构化部分成功结果 |
| Direct 审批 UI 与执行语义不一致 | P1 | 已修复 | `require` 覆盖全部 Direct 变更入口，`denied` 保持硬拒绝 |
| 并发对话订阅泄漏 subscription | P2 | 已修复 | 连接级异步互斥、单一注册对象、失败统一回滚 |

## 1. Safe 命令项目根边界

涉及文件：

- `Packages/BridgeCore/Sources/BridgeDirectCommand/DirectCommandPolicy.swift`
- `Packages/BridgeCore/Tests/BridgeDirectCommandTests/DirectCommandTests.swift`

修复内容：

- Swift 路径参数同时校验分离形式与 `--option=value` 形式，包括 `--package-path`、`--scratch-path`、`--cache-path`、`--config-path`、`--security-path`、`--toolset`、`--netrc-file`、`--attachments-path`、`--xunit-output`、`--sbom-output-dir` 等；
- Xcode 路径参数覆盖 `-xcconfig`、`-resultBundlePath`、`-archivePath`、`-exportPath`、`-clonedSourcePackagesDirPath`、`-authenticationKeyPath`、`-packageCachePath` 等；
- Xcode 测试 response file 同时覆盖分离形式和 `-only-testing:@path`/`-skip-testing:@path` 紧凑形式；
- 拒绝 Swift `--disable-sandbox` 与 Xcode 自动 provisioning 参数；
- npm 拒绝外部 cache、日志、证书、脚本解释器、workspace 和配置路径覆盖；
- 没有移除合法 CLI。Service 已验证的 Agent Reach/OpenCLI action 仍可运行并保留网络能力判断。

回归结果：`DirectCommandPolicyTests` 33 tests，0 failures。

维护约束：路径参数表依据当前 Swift/Xcode CLI help 固化；工具升级新增路径参数时必须同步扩展 validator 与逃逸测试。

## 2. 本机项目管理与 MCP 读取权限分离

涉及文件：

- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication+Helpers.swift`
- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication.swift`
- `Packages/BridgeCore/Sources/BridgeServiceHost/BridgeServiceXPCController+ProjectOperations.swift`

修复内容：

- 保留 MCP `readableProject` 的远程读取过滤；
- 新增只供本机管理面使用的 managed project 查询；
- XPC 项目列表、权限更新、命令配置和审批模式配置使用 managed 查询；
- read policy 变为 `denied` 后项目仍在 App 可见，并能恢复为 `allowed`。

真实 XPC 回归覆盖 `allowed → denied → allowed`，同时确认 MCP 权限边界没有被放宽。

## 3. 含终态任务历史的项目删除

涉及文件：

- `Packages/BridgeCore/Sources/BridgeServiceCore/SimpleServiceStore.swift`
- `Packages/BridgeCore/Sources/BridgeServiceHost/BridgeServiceXPCController+ProjectOperations.swift`
- `Packages/BridgeCore/Tests/BridgeServiceCoreTests/ServiceTaskMessageAndDeleteTests.swift`
- `Packages/BridgeCore/Tests/BridgeServiceHostTests/BridgeServiceHostTests.swift`

修复内容：

- 删除逻辑下沉到 SQLite 写事务；
- 使用完整数据库查询检查所有非终态任务，不再依赖最多 500 条的 UI 列表；
- 存在活动任务时整笔删除失败且数据保持不变；
- 仅有终态任务时，在同一事务内删除任务，再由 FK 级联清理事件与对话消息，最后删除项目。

回归测试构造了 501 条终态任务和 1 条分页范围外活动任务，验证活动任务阻断、终态历史级联清理及项目最终删除。

## 4. Direct Git commit 与真实 index

涉及文件：

- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication+DirectGitCommit.swift`
- `Packages/BridgeCore/Sources/BridgeServiceApplication/DirectGitIndexTransaction.swift`
- `Packages/BridgeCore/Sources/BridgeMCP/BridgeMCPServiceGit.swift`
- `Packages/BridgeCore/Sources/BridgeMCP/MCPServiceToolCatalog+Direct.swift`
- `Packages/BridgeCore/Sources/BridgeMCP/MCPServiceToolOutputs.swift`
- `Packages/BridgeCore/Tests/BridgeServiceApplicationTests/DirectGitCommitTransactionTests.swift`

修复内容：

- 继续用私有临时 index 隔离提交边界；
- 在创建提交前以 Git 的 `index.lock` 约定锁定真实 index，并保存锁定时快照；
- 提交成功后对快照执行 `git reset HEAD -- <changed files>`，从提交树同步条目，不再对当前工作树执行 `git add`；
- 将同步后的快照写入锁文件并原子替换真实 index；
- 提交后的外部文件编辑保持为未暂存 working-tree 变化，不会被意外加入 index；
- 真实 index 已被其他 Git 操作锁定时，在 HEAD 变化前拒绝提交；
- 如果 HEAD 已成功更新但 index 安装失败，返回成功 receipt，并明确给出 `commit_hash`、`index_synchronized=false` 与 `index_synchronization_error`，不再把不可逆提交伪装成纯失败；
- receipt 保持旧 JSON 解码兼容，旧响应缺少新字段时默认视为已同步。

回归测试覆盖真实 index 锁冲突、提交后外部编辑、提交成功后 index 安装失败以及旧 receipt 解码。

## 5. Direct 审批模式一致性

涉及文件：

- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication+DirectFiles.swift`
- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication+DirectCommand.swift`
- `Packages/BridgeCore/Sources/BridgeServiceApplication/BridgeServiceApplication+DirectGitCommit.swift`
- `Packages/BridgeCore/Tests/BridgeServiceApplicationTests/DirectActionApprovalTests.swift`

修复后的语义：

- 项目 `write=denied` 始终硬拒绝，不产生审批请求；
- 全局 `direct.approval_mode=require` 时，文件写、编辑、patch、路径管理、命令、Git commit 和 Skill action 均要求一次性本机批准；
- `auto` 保持现有自动批准语义；
- `direct_read_command`、`direct_write_stdin` 与 `direct_interrupt_command` 只控制已经批准并启动的会话，不重复创建变更入口审批。

回归测试逐一调用 7 类 Direct 变更入口，确认副作用在批准前均未发生。

## 6. 并发对话订阅所有权

涉及文件：

- `Packages/BridgeCore/Sources/BridgeServiceHost/BridgeServiceXPCController.swift`
- `Packages/BridgeCore/Sources/BridgeServiceHost/BridgeServiceXPCController+ConversationOperations.swift`
- `Packages/BridgeCore/Sources/BridgeServiceHost/BridgeServiceXPCController+Support.swift`
- `Packages/BridgeCore/Tests/BridgeServiceHostTests/ConversationStreamingHostTests.swift`

修复内容：

- 每个 XPC 连接增加异步互斥门，将替换订阅、退订和连接停止串行化；
- forwarder 与 subscription ID 合并为一个注册对象，避免两个表发生所有权分裂；
- 旧 forwarder 只能按匹配的 subscription ID 删除自身，不能误删新订阅；
- 响应编码失败时统一取消 forwarder、移除登记并退订 Service subscription；
- 连接失效时串行清空全部注册并完成退订。

回归测试覆盖 16 个同任务并发订阅和超限响应编码失败后的资源回收，最终每个连接只保留一个有效注册。

## 验收结果

| 验收项 | 命令 | 结果 |
| --- | --- | --- |
| 六项定向回归 | `swift test --filter ...` | 25 tests，0 failures |
| Safe policy 定向回归 | `swift test --filter DirectCommandPolicyTests` | 33 tests，0 failures |
| 完整 Swift 测试 | `Scripts/with-xcode.sh swift test --package-path Packages/BridgeCore` | 29 bundles，929 tests，0 failures |
| 严格格式检查 | `Scripts/with-xcode.sh xcrun swift-format lint --strict --recursive Packages/BridgeCore/Sources Packages/BridgeCore/Tests App` | 通过 |
| arm64 Debug App 构建 | `Scripts/with-xcode.sh xcodebuild -project CodexBridge.xcodeproj -scheme CodexBridge -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/Xcode build CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |
| MCP Inspector | `Scripts/verify-mcp-inspector.sh` | Inspector 2.1.0 initialize、tools/list、成功、结构化错误与 fresh connection 通过 |
| Tunnel helper 合同 | `Scripts/test-tunnel-helper-config.sh` | 官方 arm64 helper doctor、非敏感 MCP URL 与 fd-backed header 合同通过 |
| Diff 完整性 | `git diff --check` / `git diff --cached --check` | 通过 |

## 未由本轮证明的外部发布门

- 真实 ChatGPT Developer Mode 添加 MCP、工具重发现和真实对话闭环；
- 带受限 Runtime Key 的真实 Secure Tunnel；
- 正式 Developer ID 签名、Notary 和 Gatekeeper；
- `Scripts/verify-release-hardening.sh`；
- 正式签名后的嵌套 Service/helper 验证；
- 最终 UI、VoiceOver 和视觉验收。

MCP Inspector、本地测试和 unsigned Debug 构建不能替代上述外部发布门。

## 风险复核

- 原报告 5 个 P1 与 1 个 P2：**全部关闭**；
- 本地回归风险：**LOW**，完整测试、格式和构建均通过；
- 正式发布残余风险：**MEDIUM**，原因是外部 ChatGPT、Tunnel Runtime Key 与 Apple 签名链尚未执行；
- 建议发布前仍由人工安全审查者复核 Direct capability 参数表、Git index 事务和正式签名产物。

## 最终判定

**Pass（本地工程验收）**

原审查报告中的代码问题已经全部修复并形成长期回归测试。当前源码修复已提交到 `59d9c82`；审查报告与用户已有的 `AGENTS.md` 改动未包含在功能提交中。
