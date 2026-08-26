# OpenCode 连接指南

本指南适用于 Codex Bridge v0.3.0。它说明如何把本机已安装的 OpenCode 登记到 Bridge，并让 ChatGPT、Qwen Studio 或 Bridge 工作台通过 MCP 提交 OpenCode 任务。

## 先说明连接方向

OpenCode 不是 MCP 客户端，也不是要求把 Bridge 加到 OpenCode 的 MCP 列表中。正确的数据流是：

```text
ChatGPT / Qwen Studio → Codex Bridge MCP → OpenCode ACP → 已登记的本地项目
```

Bridge 会在任务批准后启动：

```text
opencode acp --cwd <已登记的项目根目录>
```

OpenCode 不随 Bridge 打包，Bridge 也不会读取、复制或导出 OpenCode 的登录凭据。

## 1. 准备 OpenCode

1. 按 OpenCode 官方方式安装并登录。
2. 确认 OpenCode 自身可以访问所需模型，并在 OpenCode 自己的权限设置中完成登录和授权。
3. 使用当前 Bridge 适配器支持的版本：`1.18.20 <= OpenCode < 1.19.0`。版本范围来自 ACP 适配器的兼容性检查，不代表 Bridge 会替你升级或降级 OpenCode。

## 2. 在 Bridge 中登记安装

1. 打开 Codex Bridge，先在“项目”页面登记要使用的本地项目。
2. 进入“设置” → “本机 Agent Provider”。
3. 点击“登记安装”，选择“OpenCode”。
4. 在文件选择器中选择真实的绝对路径下的 `opencode` 可执行文件，然后点击“登记并 Probe”。
5. Probe 成功后，确认状态为“可用”，再打开“启用”。

Bridge 不会自动扫描或执行任意候选二进制。登记时会冻结规范路径、文件身份、大小、修改时间和 SHA-256；OpenCode 更新后状态会变成“需复核”。只有在确认这是你预期的更新后，才点击“接受替换并 Probe”。

## 3. 刷新模型和设置默认模式

在工作台的“本机 Agent 任务”区域选择 OpenCode：

1. 点击“刷新模型列表”。模型目录来自当前项目根启动的 ACP `session/new.configOptions`，不是 `opencode models` CLI 的输出。
2. 选择 ACP 返回的精确模型 ID。不要手动在 `opencode-go/...` 与 `opencode/...` 之间改名或使用别名。
3. 仅当当前模型通过 ACP 声明了 effort 选项时，才选择对应 effort；没有选项时使用 Provider 默认值。
4. 选择默认执行模式：
   - **Build**：工作区可写；
   - **Plan**：只读。

模型目录只在用户点击刷新时读取。刷新失败会保留已有列表和默认设置；如果 OpenCode 删除了当前默认模型或 effort，Bridge 会清空失效的默认值。

## 4. 从工作台测试

确保 OpenCode 安装已启用、项目已选中后，在“本机 Agent 任务”卡片中选择模型并提交任务。任务仍会先进入本机审批，批准后才启动 OpenCode。OpenCode 通过 ACP 请求文件、命令、网络或其他权限时，也会回到 Bridge 工作台等待本机用户审批。

## 5. 从 ChatGPT 或 Qwen 通过 MCP 使用

先调用 `list_projects` 获取不透明的项目 ID，再调用 `list_agents` 确认 OpenCode 安装满足：

```json
{
  "provider_id": "opencode",
  "availability": "available",
  "enabled": true,
  "task_submission_enabled": true
}
```

最小任务请求：

```json
{
  "project_id": "<list_projects 返回的项目 ID>",
  "provider_id": "opencode",
  "prompt": "检查项目结构并总结当前构建问题。",
  "network_access": false
}
```

只有用户明确要求覆盖模型或权限模式时，才增加覆盖字段：

```json
{
  "project_id": "<项目 ID>",
  "provider_id": "opencode",
  "installation_id": "<可选的 installation_id>",
  "prompt": "修复指定测试失败，并运行相关测试。",
  "model_override": true,
  "execution_model": "<ACP 返回的精确 model_id>",
  "execution_effort": "<该模型实际支持的 effort>",
  "permission_mode": "workspace-write",
  "permission_mode_override": true,
  "network_access": false,
  "acceptance_criteria": [
    "相关测试通过",
    "只修改项目内文件"
  ],
  "client_request_id": "<客户端生成的幂等 ID>"
}
```

字段规则：

- `provider_id` 为 `opencode`；省略时仍走默认 Codex 路径。
- `installation_id` 可省略，Bridge 会选择已启用且 Probe 可用的安装。
- `execution_model` 和 `execution_effort` 只有在 `model_override=true` 时才覆盖本次任务。
- `permission_mode` 只能是 `read-only` 或 `workspace-write`；它们分别映射为 ACP Plan 和 Build。
- 只有用户明确要求本次模式时，才设置 `permission_mode_override=true`。
- 当前 OpenCode ACP 没有 Bridge 级逐任务网络沙箱，因此 `network_access=true` 会被拒绝；网络行为由 OpenCode 原生权限设置控制。
- OpenCode 任务不要携带 `thread_id`、`skill_name`、`supervisor_model` 或 `supervisor_effort`。
- 项目本身禁止写入时，默认 Build 会安全收窄为只读，不会越过项目策略。

## 6. 审批、查询和继续任务

`submit_task` 通常先返回 `awaiting_local_approval`。本机用户在 Bridge 工作台批准后，任务才进入 `starting` 和 `running`。使用 `get_task` 查询阶段、`result_summary`、`failure_code`、`recent_activity`、`execution_model`、`execution_effort`、`permission_mode` 以及 Provider 绑定字段；进入终态后调用 `get_final_report` 获取结构化最终报告。

不要因为 `updated_at` 暂时不变、`recent_activity` 为空或任务较安静就推断失败；按 `get_task` 返回的 `wait_policy` 继续轮询，终态才是权威结果。

OpenCode 的 `steer_task` 和 `interrupt_task` 使用 `get_task` 返回的 `provider_run_id` 填入 `expected_turn_id`：

```json
{
  "task_id": "<任务 ID>",
  "expected_turn_id": "<provider_run_id>",
  "input": "继续处理剩余测试，并优先修复编译错误。"
}
```

Bridge 会在同一个 ACP Session 中把 steer 内容排队为后续 prompt；中断会优先处理并丢弃尚未执行的 steer 队列。

## 7. 权限和数据隔离

- Bridge 的 Plan/Build 只映射 OpenCode 的原生执行模式，不会伪造或绕过 OpenCode 权限。
- OpenCode 的全局 XDG 配置、认证和插件由 OpenCode 自己管理；每个 Bridge 任务的 `HOME`、cache、state、runtime 和 `OPENCODE_DB` 都使用隔离目录。
- Bridge 不读取或回传 OpenCode auth 文件、Token、Cookie 或 Runtime Key。
- 远程客户端不能批准任务或 ACP 权限请求，所有批准都必须由本机用户完成。

## 8. 常见问题

| 状态或问题 | 处理方式 |
|---|---|
| 没有可用安装 | 重新登记绝对路径下的真实可执行文件并 Probe，确认已启用。 |
| `needs_review` /“需复核” | 二进制身份发生变化；确认来源可信后点击“接受替换并 Probe”。 |
| 版本或 ACP 不兼容 | 使用 `1.18.20 <= OpenCode < 1.19.0` 范围内的官方版本。 |
| 模型列表为空 | 先选择项目，再点击“刷新模型列表”；目录必须来自 ACP。 |
| 模型不可用 | 使用 ACP 返回的精确 ID，不要使用跨 Provider 别名。 |
| `network_access=true` 被拒绝 | 改为 `false`，并在 OpenCode 原生权限中配置网络行为。 |
| `awaiting_local_approval` | 打开 Bridge 工作台批准任务；ChatGPT/Qwen 无法代替本机批准。 |
| `project_busy` | 等待同一项目的其他写任务或 Direct 操作完成。 |
| `unknown` | 检查 Service/Provider 是否重启；不要自动伪造恢复或启动新任务。 |
| 下载的 App 无法直接打开 | Finder 中对 App 使用“右键 → 打开”，或到“系统设置 → 隐私与安全性”选择“仍要打开”。发布包未配置 Developer ID，也未公证。 |

移除登记只会删除 Bridge 的本地安装记录，不会删除 OpenCode 可执行文件、登录状态或 OpenCode 自己的配置。
