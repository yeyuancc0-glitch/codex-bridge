# Antigravity / AGY 连接与权限指南

本指南说明如何让 Antigravity CLI 在 Codex Bridge 中正常完成只读分析、联网检索和项目写入。Bridge 使用的是 `agy` CLI 的 headless `stream-json` 模式，不是 Antigravity Desktop App。

Provider ID 固定为：

```text
antigravity
```

省略 `provider_id` 时，Bridge 会使用 Codex，不会自动选择 AGY。

## 1. 先理解权限链

AGY 任务能否成功由三层共同决定：

```text
Bridge 项目和任务模式
        ↓
Bridge 远程任务启动批准
        ↓
agy CLI 原生 Sandbox + Permissions
```

最常见的误区是只在 Bridge 中选择 `Write`，却没有配置 AGY CLI 自己的权限。Bridge 不能在 headless `stream-json` 中回答 AGY 的交互式确认；需要询问但没有提前放行的工具会被 AGY 拒绝或软拒绝。

| 设置 | 控制什么 |
| --- | --- |
| `项目 → 访问与执行权限` | 项目可读、是否允许进入写模式，以及用户期望的网络边界 |
| `工作台 → GPT/Qwen 新任务` | ChatGPT/Qwen 默认使用 `Read Only` 还是 `Write` |
| “批准启动” | 是否启动这一次远程 Provider 任务 |
| AGY `/settings` | Tool Permission 等 CLI 全局行为 |
| AGY `/permissions` | 哪些命令、URL 和 MCP 工具可以在 headless 中直接执行 |

“自动批准远程 Agent 启动请求”只跳过启动批准，不批准 AGY 工具。Antigravity Desktop 的自动执行设置也不等于 CLI 的权限设置。

> **正常使用前必须确认**：在交互式 `agy` 中打开 `/settings`（或 `/config`），将 **Tool Permission** 设为 `proceed-in-sandbox`，也就是允许沙箱内终端命令自动执行。Bridge 启动 AGY 时已经强制传入 `--sandbox`；如果设置页显示 Sandbox Mode 被命令行覆盖为开启，这是预期行为。

## 2. 兼容要求

当前 Bridge 接受：

```text
1.1.21 <= agy < 1.2.0
```

Probe 还会检查当前 `agy --help` 是否提供：

- `--input-format stream-json`
- `--output-format stream-json`
- `--mode plan`
- `--mode accept-edits`
- `--sandbox`
- `--dangerously-skip-permissions`
- `--conversation`
- `--model`
- `--effort`

仅版本号匹配但缺少这些能力，安装仍会显示不可用。

## 3. 安装并找到正确的 AGY 二进制

### 3.1 安装

如果尚未安装，请先阅读 [Antigravity CLI Installation & Auth](https://antigravity.google/docs/cli/install/)。当前官方 macOS/Linux 安装命令为：

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

默认会把 AGY 安装到当前用户的：

```text
~/.local/bin/agy
```

安装脚本和版本可能更新；以官方安装页为准。企业账号、代理或 Keychain 认证也应按该页配置，不要把认证材料交给 Bridge。

### 3.2 找到二进制

在终端运行：

```bash
command -v agy
agy --version
agy --help
```

`command -v agy` 输出的文件就是 Bridge 应登记的二进制。例如：

```text
/Users/你的用户名/.local/bin/agy
```

不要选择：

- Antigravity Desktop 的 `.app`；
- `/Applications/Antigravity.app` 内任意可执行文件；
- 一个只包含快捷方式但目标已失效的路径；
- 从其他账号目录复制来的 AGY。

如果路径位于 `.local` 等隐藏目录，在 Bridge 文件选择器中按 `⌘⇧G`，粘贴 `command -v agy` 的完整输出，再选择该文件。

## 4. 先用同一 macOS 用户完成 CLI 登录

Bridge 启动 AGY 时继承当前用户的 `HOME` 和登录状态。先在准备使用的项目根目录运行一次交互式 CLI：

```bash
cd /path/to/your/project
agy
```

按 AGY 自己的流程完成登录，确认能够进入交互界面并看到可用模型。然后退出即可。

不要用临时或隔离的 `HOME` 测试 `agy` 登录；没有现有登录状态时，AGY 可能重新打开浏览器 OAuth。不要把浏览器返回的授权码、Token、Cookie 或账号信息粘贴到 Bridge、聊天、日志或 Issue。

## 5. 正确配置 AGY 原生权限

### 5.1 正常使用前确认 Tool Permission

在目标项目根目录启动交互式 `agy`，输入：

```text
/settings
```

也可以使用别名：

```text
/config
```

找到 **Tool Permission**，将其设为：

```text
proceed-in-sandbox
```

这就是“沙箱内终端命令自动执行”。Bridge 每次启动 AGY 都会传入 `--sandbox`，所以不需要再依赖 Desktop 的 Sandbox 设置；AGY 设置页可能显示 Sandbox Mode 被命令行参数覆盖为开启。不能进入 Sandbox 的命令仍会按权限规则处理。

其他模式的含义：

| 模式 | 行为 | Bridge 使用建议 |
| --- | --- | --- |
| `request-review` | 写入、命令和网络操作通常要求交互确认 | 交互式 AGY 安全，但未预先放行的工具在 Bridge headless 中会被拒绝 |
| `proceed-in-sandbox` | Sandbox 内命令可自动运行 | 推荐起点 |
| `strict` | 更多非读取操作要求确认 | 适合纯交互审查，不适合作为未配置规则的 Bridge 默认 |
| `always-proceed` | 所有工具尽量自动运行 | 风险高，不建议作为长期全局设置 |

AGY 将持久设置保存在：

```text
~/.gemini/antigravity-cli/settings.json
```

优先通过 `/settings` 和 `/permissions` 修改，避免手工写错 JSON。Antigravity Desktop 的设置不会可靠替代这里的 CLI 配置。

### 5.2 用 `/permissions` 添加窄规则

仍在目标项目的交互式 `agy` 中输入：

```text
/permissions
```

按以下顺序操作：

1. 在 Scope Picker 中优先选择 **Project**，只让规则作用于当前项目；只有确实希望所有项目共享时才选择 **Global**。
2. 进入规则列表后切换到 **allow** 页。
3. 按 `A` 添加规则。
4. 输入 `action(target)` 形式的规则并保存。
5. 检查 **ask** 和 **deny** 页是否存在更宽的冲突规则。

常用规则示例：

```text
command(git status)
command(git diff)
command(swift test)
read_url(developer.apple.com)
execute_url(example.com)
mcp(server-name/tool-name)
```

规则含义：

| 操作 | 规则形式 | 示例 |
| --- | --- | --- |
| Shell | `command(命令前缀)` | `command(pnpm test)` |
| 读取网页 | `read_url(域名)` | `read_url(github.com)` |
| 操作网页 | `execute_url(域名)` | `execute_url(platform.openai.com)` |
| MCP | `mcp(server/tool)` | `mcp(linter/check)` |
| 工作区文件 | `read_file(path)` / `write_file(path)` | 只在确有需要时为项目内相对路径添加 |

AGY 的优先级是：

```text
deny > ask > allow
```

例如存在 `ask: command(*)` 时，即使 allow 中有 `command(git status)`，仍可能要求确认。只在理解影响后缩小冲突规则；不要用 `command(*)`、`read_url(*)` 或 `mcp(*)` 代替必要的精确授权。

### 5.3 文件写入为何通常不需要额外规则

Bridge 对写任务传入：

```text
--mode accept-edits
```

AGY 的 Accept Edits 会自动批准活动工作区内的标准文件创建和修改。Shell、Web、MCP、工作区外路径仍是独立权限，必须由 `/permissions` 或其他明确策略处理。

只读任务则传入：

```text
--mode plan
```

Plan 用于分析和规划，不应依赖它修改项目文件。

## 6. 在 Bridge 中登记

1. 打开 `连接 → 本机 Agent 引擎连接`。
2. 点击“登记 Agent”。
3. 选择“Antigravity”。
4. 选择第 3 节 `command -v agy` 返回的真实文件。
5. 点击“登记并 Probe”。
6. 检查版本、能力和状态。
7. 状态为“可用”后打开“启用”。

登记成功不会自动启用。AGY 更新或二进制身份变化后，Bridge 会显示 `needs_review`；核对新版本仍在兼容范围内，再点击“接受替换并 Probe”。

## 7. 刷新模型和默认值

1. 先在 `工作台` 选择真实任务项目。
2. 打开 `设置 → Antigravity 执行默认偏好`。
3. 有多个安装时选择目标 AGY。
4. 刷新模型列表。
5. 选择 AGY 当前返回的精确 model 和 effort。
6. 选择 Provider 默认访问权限：只读或工作区可写。

对 ChatGPT/Qwen 新任务，`工作台 → GPT/Qwen 新任务 → Read Only / Write` 优先于这里的 Provider 默认。远程客户端通常应省略 `permission_mode`，让 Workbench 决定；只有用户明确要求单任务覆盖时才同时发送 `permission_mode_override=true`。

## 8. Bridge 实际如何启动 AGY

只读任务的核心参数：

```text
agy
--sandbox
--input-format stream-json
--output-format stream-json
--mode plan
--add-dir <项目根>
```

写任务的核心参数：

```text
agy
--sandbox
--input-format stream-json
--output-format stream-json
--mode accept-edits
--add-dir <项目根>
```

Bridge 不再给 AGY 套外层 `sandbox-exec`。真实文件、命令、Web 和 MCP 约束由 AGY 原生 Sandbox、执行模式和权限规则负责。

## 9. 三种正常使用场景

### 9.1 只读分析，不联网

Bridge：

1. `项目`：读取“允许”、写入“拒绝”。
2. `工作台`：选择正确项目和 `Read Only`。
3. `设置 → Antigravity 执行默认偏好`：默认权限选“只读”。
4. 任务使用 `network_access=false`。

请求示例：

```json
{
  "provider_id": "antigravity",
  "prompt": "只读分析当前项目并说明问题，不要修改文件。",
  "network_access": false
}
```

这种任务会使用 `--mode plan`，不会加入 `--dangerously-skip-permissions`。如果 prompt 要求运行 Shell，仍应提前添加对应的窄 `command(...)` allow 规则。

### 9.2 只读联网

1. 保持 Workbench 为 `Read Only`。
2. 项目读取设为“允许”，网络意图设为“允许”或“需要本机批准”。
3. 在 AGY `/permissions` 中只放行需要访问的 `read_url(domain)`、`execute_url(domain)`，以及必要命令/MCP。
4. 任务显式发送 `network_access=true`。

```json
{
  "provider_id": "antigravity",
  "prompt": "搜索并核对官方资料，给出来源；不要修改项目。",
  "network_access": true
}
```

`network_access=true` 只表达用户明确的联网意图，不会替你创建 AGY allow 规则。当前项目网络选择器也不是外部 Provider 的网络包级防火墙；最终仍以 AGY 原生 `read_url`、`execute_url`、Sandbox 和命令规则为准。

原生 `search_web` 可能不需要本地缓存写入，但 `read_url_content`、浏览器、第三方插件或辅助脚本可能需要额外 URL、命令、MCP 或本地状态权限。看到拒绝时按失败的具体工具补最窄规则，不要直接开放全部权限。

### 9.3 修改项目文件

1. `项目`：读取“允许”、写入“允许”。
2. `工作台`：选择 `Write`。
3. 确认同一项目没有其他活动写任务。
4. 在 AGY `/permissions` 中放行构建、测试和查询所需的窄命令/网络规则。
5. 任务不需要联网时使用 `network_access=false`。

```json
{
  "provider_id": "antigravity",
  "prompt": "实现指定修改并运行相关测试。",
  "network_access": false
}
```

Bridge 使用 `--mode accept-edits`，同一项目的写任务进入独占 workspace gate。项目写入为“需要本机批准”不会给 AGY 增加逐文件审批；希望硬性禁止写入时应选择“拒绝”。

## 10. 高风险兜底：`full-access + network_access=true`

只有同时满足以下两项，Bridge 才会为 AGY 增加 `--dangerously-skip-permissions`：

1. `设置 → Codex 执行默认偏好 → 访问权限` 选择“完全访问权限（full-access）”；
2. 当前任务明确发送 `network_access=true`。

此时启动参数仍包含：

```text
--sandbox
--mode plan
```

或：

```text
--sandbox
--mode accept-edits
```

它不会移除 AGY Sandbox，也不会把只读任务改成写任务；但它会跳过该次 AGY 的所有工具确认，包括命令、文件和 MCP。这个 access mode 是 Service 共用设置，可能同时影响 Codex 等任务，不要作为长期默认。优先使用 Project 作用域的窄 `/permissions` 规则；只有完全信任 prompt、项目和工具时才临时使用，任务结束后改回“请求批准”。

`auto-review`、自动批准远程任务启动、Direct 自动批准都不会产生同样效果。

## 11. 从 ChatGPT/Qwen 提交

先让客户端调用：

```text
list_projects
list_agents
list_models
```

确认：

- `provider_id` 为 `antigravity`；
- 安装 `availability` 为 `available`；
- `enabled` 与 `task_submission_enabled` 为 `true`；
- Workbench 已选中正确项目和权限。

有多个 AGY 安装时，使用 `list_agents` 返回的精确 `installation_id`。模型覆盖只在用户明确指定时设置 `model_override=true`，model/effort 必须来自当前 AGY 目录。

远程任务默认先进入：

```text
awaiting_local_approval
```

在 Bridge 工作台核对项目、Provider、Read Only/Write、网络意图和 prompt 后点击“批准启动”。AGY 后续工具不会进入可交互的 App 审批卡片；权限不足时应回到 AGY `/permissions` 修正规则后重试。

## 12. 常见故障

| 现象 | 正确处理 |
| --- | --- |
| 找不到可执行文件 | 运行 `command -v agy`；在文件选择器按 `⌘⇧G` 粘贴该绝对路径 |
| 误选 Desktop App | 重新登记真实 `agy` CLI；Bridge 不运行 Antigravity Desktop |
| Probe 版本不兼容 | 使用 `1.1.21 <= agy < 1.2.0` 且当前 `--help` 包含必需能力的版本 |
| 显示 `needs_review` | 二进制已变化；核对来源和版本后“接受替换并 Probe” |
| Bridge 中提示未登录 | 用同一 macOS 用户在普通 `HOME` 下交互运行 `agy` 完成登录 |
| `permission_mode=request-review` 后工具被拒绝 | 在交互式 AGY 用 `/settings` 选择 `proceed-in-sandbox`，并用 `/permissions` 添加窄 allow 规则 |
| 已添加 allow 仍被询问 | 检查 ask/deny 是否匹配同一操作；AGY 优先级为 `deny > ask > allow`，并确认规则作用域是当前 Project |
| Shell 仍被拒绝 | 放行精确 `command(...)`；若命令必须逃离 Sandbox，应先评估风险，不要默认扩大到全部命令 |
| Web/URL 被拒绝 | 任务发送 `network_access=true`，并为具体域名添加 `read_url(domain)` / `execute_url(domain)` |
| MCP 工具被拒绝 | 在 AGY `/permissions` 添加精确 `mcp(server/tool)`，不是修改 Bridge MCP 客户端权限 |
| Desktop 已设自动执行仍无效 | Desktop 与 CLI 设置来源不同；检查 AGY `/settings` 和 `/permissions` |
| 只读搜索能用，URL/辅助脚本失败 | 后者可能需要 URL、命令、MCP 或缓存写入权限；按实际失败工具补窄规则 |
| 写任务没有修改文件 | Workbench 是否为 `Write`、项目写入是否允许、任务是否实际使用 `--mode accept-edits` |
| 打开 `full-access` 仍没有 skip 参数 | 该次任务还必须明确 `network_access=true`；此组合只用于完全可信任务 |

## 13. 安全与验收

- 不读取、复制或提交 AGY 的认证文件、Token、Cookie 或浏览器授权响应。
- 优先使用 Project 作用域和精确规则，不使用全局通配符代替必要配置。
- Probe 成功只证明二进制、版本、帮助能力和基础 Provider 行为可用，不证明账号额度、Web、Shell、MCP 或写入已验收。
- 最终使用自己的账号，在可回滚的测试项目中分别验证只读、联网、写入、命令和会话继续。

## 14. 参考

- [Antigravity CLI Installation & Auth](https://antigravity.google/docs/cli/install/)
- [Antigravity CLI Settings](https://antigravity.google/docs/cli/settings/)
- [Antigravity CLI Permissions](https://antigravity.google/docs/cli/permissions/)
- [Permissions Command](https://antigravity.google/docs/cli/commands/permissions/)
- [Antigravity CLI Headless Mode](https://antigravity.google/docs/cli/headless/)
- [Codex Bridge 详细使用指南](./USER_GUIDE.md)
