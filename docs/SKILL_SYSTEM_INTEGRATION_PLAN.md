# Codex Bridge Skill 系统接入方案与架构规范

> 本文是实施规范。已落地部分以当前代码和测试为准；本文不授权新增第二套执行控制平面。

## 实施修订（2026-08）

### 已确定的边界

1. **Skill 是本机只读能力目录，不是新的权限来源。** `SKILL.md` 只向 ChatGPT 提供上下文；它不能授予项目访问、文件写入、网络或命令执行权限。
2. **物理路径不进入 MCP 返回值。** Service 只接受不透明 `project_id`，全局目录由 Service 进程按固定根解析；Skill manifest 的根路径只保留在 Service 内部。
3. **项目 Skill 优先于全局 Skill。** 项目扫描顺序为 `skills/`、`.agents/skills/`、`.codex/skills/`；同名 Skill 只保留第一个。全局扫描顺序为 `~/.codex/skills/`、`~/.agents/skills/`、`~/.gemini/config/skills/`。
4. **上下文必须显式。** 不带 `project_id` 只能列出全局 Skill；读取或列出项目 Skill 必须提供已注册项目 ID，禁止根据当前目录、标题或最近 Thread 猜测项目。
5. **规则文件按需读取，不持久化内容。** Scanner 即时枚举和读取，单 Skill 数量、名称、文档大小、输出大小均受硬上限约束，避免缓存陈旧规则和把 Skill 内容写入 Service 数据库。
6. **安全读取不等于执行安全。** Skill 目录中的 `.env*`、私钥、认证文件、符号链接逃逸和绝对路径均拒绝；参考文件必须相对 `SKILL.md` 所在 Skill 根目录解析，并通过 `SensitivePathPolicy`。
7. **Phase 1 只交付 `list_skills` 与 `read_skill`。** 这两个工具在 read-only/full MCP 中都可用。`run_skill_action` 延后到明确的命令契约完成后实现，执行时复用 `BridgeDirectCommand` 的 argv 解析、项目策略、审批、workspace gate、超时和进程组生命周期。

### 当前落地状态

- `BridgeSkills` 模块已提供 `SkillManifest`、`SkillAction`、`SkillDocument`、`SkillScanner` 和统一错误类型。
- Skill manifest 以真实 YAML Frontmatter 解析（`SkillFrontmatter`）：支持 `>`/`|` block scalar、block sequence、嵌套 map、inline 数组与引号，不再按行找冒号。
- Skill Action 以显式契约暴露：`name + scriptPath + interpreter + requiresNetwork`。优先读取 `actions:` 元数据；否则自动发现 `scripts/` 顶层中带合法 shebang 或已知解释器扩展（`.sh`/`.py`/`.mjs` 等）的可执行入口，`lib/`、`detector/**`、JSON 等内部文件不会进入动作列表。
- `BridgeMCP` 已增加 `list_skills`、`read_skill`、`run_skill_action` 的版本化结构化响应，未返回 Skill 物理根路径；`run_skill_action` 以 `action_name` 引用 Action。
- `BridgeServiceApplication` 通过已批准项目根调用 Scanner；项目访问权限仍由现有 `readableProject` 校验。
- `run_skill_action` 已接入 Full MCP：只允许执行 Scanner 暴露的 Action，解释器从 Action 元数据或 shebang 解析为绝对路径（绝不猜测），执行复用 Direct Command 会话；安全模式通过内部验证标记放行该已发现 Action，黑名单、审批、workspace gate、进程组、超时和输出边界仍然生效。
- 网络隔离是硬边界而非信任声明：Action 声明 `requiresNetwork=false` 时，进程在 `sandbox-exec (deny network*)` 包裹下启动，脚本自身代码无法联网；`sandbox-exec` 不可用时 fail-closed（`network_isolation_unavailable`），调用方不再能传 `network_access` 覆盖。
- `submit_task` 支持可选 `skill_name`，Service 读取权威 `SKILL.md` 并以有界上下文注入 Codex prompt；Skill 不成为权限来源。
- XPC/App 已增加项目 Skill 查询与展示，不保存 Skill 内容和物理路径。

### 后续验收门

1. Phase 1：覆盖项目/全局发现、同名覆盖、无项目上下文、frontmatter、UTF-8/大小限制、敏感文件、`..`、符号链接和 MCP 结构化契约。
2. Phase 2：已完成。仅允许 manifest 中已发现且位于 Skill 根目录内的脚本；脚本 argv 不经 shell，复用现有项目命令策略并保留本机审批。
3. Phase 3：已完成。App 只展示 Skill 名称、描述、来源和能力摘要，不展示绝对路径或自动执行 Skill。
4. Phase 4：真实 ChatGPT Developer Mode 验证“发现 → 读取规则 → 使用现有项目工具/提交 Codex 任务”的闭环；不能用 Inspector 通过替代真实验收。

## 一、方案背景与目标

### 1. 目标概述
为 **Codex Bridge** 构建一套轻量、安全、且对齐业界标准（Codex / Claude Code / Antigravity）的 **Skill 扩展系统**。使网页端 ChatGPT 通过 MCP 能够：
1. **自动发现并加载本地已安装的 Skill**：直接复用本地 Codex 已安装的 Skills（`~/.codex/skills/`）以及项目私有 Skills（`<ProjectRoot>/skills/` 或 `.agents/skills/`），无需二次安装或文件迁移（Zero-Copy）。
2. **支持双轨调用姿态**：
   * **GPT 直驱模式（In-Context Direct）**：适用于代码审查（`code-review`）、前端设计规范（`f-design`）、联网搜索（`agent-reach`）等轻量或单轮交互类 Skill。
   * **Codex 代理模式（Autonomous Delegation）**：适用于涉及多文件批量修改、多轮编译自愈、长程 Agent 循环的重型 Skill。
3. **保持既有安全与并发红线**：
   * 严格防止路径逃逸与符号链接越界；
   * 严格过滤敏感凭据（`.env*`、私钥、Token）；
   * 命令执行受项目既有 `direct_command_mode`（`safe`/`full`）、超时熔断、进程组隔离及本机用户审批机制约束。

---

## 二、系统总体架构与交互拓扑

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ChatGPT Web (MCP Client)                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                           (Secure MCP Tunnel / NIO)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              BridgeMCP 层                                   │
│  ├── list_skills              (发现本地全局与项目级 Skills)                 │
│  ├── read_skill               (读取 SKILL.md / 参考手册与使用规范)         │
│  └── run_skill_action         (执行 Skill 附带的本地 CLI/辅助脚本)          │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          BridgeServiceCore 核心域                           │
│  ├── SkillScanner             (路径安全校验、YAML Frontmatter 解析与缓存)   │
│  ├── BridgeDirectCommand      (安全模式、白名单/黑名单校验、进程组与超时)   │
│  └── ServiceWorkspaceGate     (项目单活动写锁、写任务互斥门禁)              │
└─────────────────────────────────────────────────────────────────────────────┘
          │                                                   │
          ▼                                                   ▼
┌──────────────────────────────────────┐     ┌────────────────────────────────┐
│          本地 Skill 物理目录         │     │         Native macOS App       │
│  ├── ~/.codex/skills/ (Codex 已安装) │     │  (XPC 订阅，展示已装载 Skills  │
│  ├── <ProjectRoot>/skills/           │     │   及命令执行本机审批)          │
│  └── <ProjectRoot>/.agents/skills/   │     └────────────────────────────────┘
└──────────────────────────────────────┘
```

---

## 三、核心模块与数据模型设计

### 1. 数据模型（`BridgeServiceCore/SkillModels.swift`）

```swift
import Foundation

public enum SkillScope: String, Codable, Sendable {
  case project   // 项目级私有 Skill (<ProjectRoot>/skills/ 或 .agents/skills/)
  case global    // 全局已安装 Skill (~/.codex/skills/ 或 ~/.gemini/config/skills/)
}

public struct SkillAction: Identifiable, Codable, Equatable, Sendable {
  public var id: String { name }
  public let name: String
  public let scriptPath: String
  public let interpreter: String?
  public let requiresNetwork: Bool
  public let description: String
}

public struct SkillManifest: Identifiable, Codable, Equatable, Sendable {
  public var id: String { name }
  public let name: String
  public let description: String
  public let scope: SkillScope
  public let rootPath: String
  public let triggers: [String]
  public let actions: [SkillAction]
  public let hasReferences: Bool

  public init(
    name: String,
    description: String,
    scope: SkillScope,
    rootPath: String,
    triggers: [String] = [],
    actions: [SkillAction] = [],
    hasReferences: Bool = false
  ) {
    self.name = name
    self.description = description
    self.scope = scope
    self.rootPath = rootPath
    self.triggers = triggers
    self.actions = actions
    self.hasReferences = hasReferences
  }
}

public struct SkillDocument: Codable, Equatable, Sendable {
  public let name: String
  public let subpath: String
  public let content: String
  public let byteCount: Int
}
```

### 2. 安全扫描器（`BridgeServiceCore/SkillScanner.swift`）

负责发现目录、解析 `SKILL.md` 的 YAML Frontmatter，并进行严格的沙箱防逃逸检查：

```swift
public actor SkillScanner {
  private let globalRoots: [URL]
  private var cachedManifests: [String: [SkillManifest]] = [:]

  public init(globalRoots: [URL] = defaultGlobalRoots()) {
    self.globalRoots = globalRoots
  }

  public static func defaultGlobalRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent(".codex/skills"),
      home.appendingPathComponent(".gemini/config/skills"),
      home.appendingPathComponent(".agents/skills")
    ].filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 扫描指定项目与全局环境中的 Skills
  public func scanSkills(for projectRoot: URL?) throws -> [SkillManifest] {
    var results: [SkillManifest] = []
    var seenNames: Set<String> = []

    // 1. 优先扫描项目私有目录（同名覆盖全局）
    if let projectRoot {
      let projectCandidates = [
        projectRoot.appendingPathComponent("skills"),
        projectRoot.appendingPathComponent(".agents/skills"),
        projectRoot.appendingPathComponent(".codex/skills")
      ]
      for candidate in projectCandidates {
        if FileManager.default.fileExists(atPath: candidate.path) {
          let projectSkills = try scanDirectory(candidate, scope: .project)
          for skill in projectSkills where !seenNames.contains(skill.name) {
            results.append(skill)
            seenNames.insert(skill.name)
          }
        }
      }
    }

    // 2. 扫描全局已安装目录 (~/.codex/skills 等)
    for globalRoot in globalRoots {
      let globalSkills = try scanDirectory(globalRoot, scope: .global)
      for skill in globalSkills where !seenNames.contains(skill.name) {
        results.append(skill)
        seenNames.insert(skill.name)
      }
    }

    return results.sorted { $0.name < $1.name }
  }

  /// 安全读取 Skill 规则文件（防路径穿越与符号链接逃逸）
  public func readSkillDocument(
    manifest: SkillManifest,
    subpath: String = "SKILL.md",
    maximumBytes: Int = 64 * 1024
  ) throws -> SkillDocument {
    let rootURL = URL(fileURLWithPath: manifest.rootPath).standardizedFileURL
    let targetURL = rootURL.appendingPathComponent(subpath).standardizedFileURL

    // 校验目标路径必须在 Skill 根目录内
    guard targetURL.path.hasPrefix(rootURL.path) else {
      throw SkillError.pathEscapeDetected(subpath)
    }

    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SkillError.documentNotFound(subpath)
    }

    let data = try Data(contentsOf: targetURL, options: .mappedIfSafe)
    guard data.count <= maximumBytes else {
      throw SkillError.documentTooLarge(actualBytes: data.count, maxBytes: maximumBytes)
    }

    guard let content = String(data: data, encoding: .utf8) else {
      throw SkillError.invalidEncoding
    }

    return SkillDocument(
      name: manifest.name,
      subpath: subpath,
      content: content,
      byteCount: data.count
    )
  }
}
```

---

## 四、MCP 接口契约定义（`BridgeMCP`）

在 `MCPServiceToolCatalog.swift` 中扩展三个标准 MCP 工具：

### 1. `list_skills`（只读，开箱即查）
* **描述**：列出本地 Codex 已安装与当前项目挂载的所有可用 Skills。
* **参数**：
  * `project_id`（可选）：指定项目 ID 时，合并该项目的私有 Skills。
* **返回格式**：
  ```json
  {
    "skills": [
      {
        "name": "agent-reach",
        "description": "多平台互联网检索与信息调研工具 (Exa, GitHub, B站, Twitter等)",
        "scope": "global",
        "triggers": ["调研", "search", "github", "bilibili"],
        "actions": [
          {
            "name": "search",
            "script_path": "scripts/search.py",
            "interpreter": "/opt/homebrew/bin/python3",
            "requires_network": true,
            "description": ""
          }
        ]
      },
      {
        "name": "code-review",
        "description": "严格的数据结构、安全性与架构极简主义代码审查规范",
        "scope": "global",
        "triggers": ["review", "审查", "cr"],
        "actions": []
      }
    ]
  }
  ```

### 2. `read_skill`（只读，规则注入）
* **描述**：读取指定 Skill 的 `SKILL.md` 或 `references/` 详细参考手册。
* **参数**：
  * `skill_name`（必填）：Skill 名称。
  * `subpath`（可选，默认 `"SKILL.md"`）：可指定阅读子参考文档（如 `"references/search.md"`）。
  * `project_id`（可选）：指定项目上下文。
* **返回格式**：
  ```json
  {
    "name": "agent-reach",
    "subpath": "SKILL.md",
    "content": "# Agent Reach — 互联网能力路由器\n...",
    "byte_count": 6096
  }
  ```

### 3. `run_skill_action`（受权限管辖的执行工具）
* **描述**：运行指定 Skill 内置的辅助脚本或专用 CLI。
* **参数**：
  * `skill_name`（必填）：Skill 名称。
  * `action_name`（必填）：Skill Action 名称（`list_skills` 返回的 `actions[].name`）。
  * `arguments`（可选）：参数数组 `[String]`。
  * `project_id`（必填）：执行时绑定的项目工作区上下文。
* **返回格式**：
  ```json
  {
    "skill_name": "agent-reach",
    "action_name": "search",
    "exit_code": 0,
    "stdout": "...",
    "stderr": "",
    "truncated": false
  }
  ```
* **网络隔离**：Action 的 `requires_network` 是唯一网络来源；`false` 时进程在 `sandbox-exec (deny network*)` 下启动，脚本自身无法联网，调用方不能传 `network_access` 覆盖，`sandbox-exec` 不可用时 fail-closed。

---

## 五、双轨执行姿态与工作流协同

```text
                                ChatGPT Web 识别任务需求
                                           │
             ┌─────────────────────────────┴─────────────────────────────┐
             ▼                                                           ▼
     【单轮/工具/轻量工作流】                                     【长程自主/多轮修复/多Agent】
  1. 调用 read_skill 加载规范                                 1. ChatGPT 调用 submit_task
  2. ChatGPT 自身按规范生成代码                                2. 将 Skill 目标注入 Prompt
  3. 通过 direct_edit_file 或                                3. 本地 Codex 引擎在后台自主
     run_skill_action 运行并获取结果                            加载 Skill、跑测试并由 Supervisor 监督
```

1. **姿态一：网页 GPT 直驱（In-Context Direct）**
   * **适用场景**：`code-review` 代码审查、`f-design` 前端规范设计、`agent-reach` 网页/GitHub 检索。
   * **执行逻辑**：GPT 调 `read_skill` 将规范加载进自身 Context，直接按照规范执行或生成代码，通过 `direct_edit_project_file` 瞬间落盘。
2. **姿态二：Codex 代理运行（Autonomous Delegation）**
   * **适用场景**：复杂重构、需要执行多轮“编译→排错→修复”死循环的 Agent 类 Skill。
   * **执行逻辑**：GPT 调 `submit_task` 将目标与 Skill 要求提交给本地 `codex app-server`。Codex 原生加载该 Skill 在独立进程中自主完成，完成后向 GPT 返回摘要。

---

## 六、安全边界与防护规范

1. **路径封禁与沙箱隔离**：
   * 严格禁止读取 Skill 目录以外的文件，拒绝绝对路径及 `..` 越界解析；
   * 严格遵循 `BridgeSecurity` 规则：Skill 目录内的 `.env*`、私钥、OAuth Token 默认自动屏蔽。
2. **命令执行策略完全对齐**：
   * `run_skill_action` 必须继承当前项目的 `direct_command_mode`：
     * `denied`：禁止执行任何 Skill 脚本；
     * `safe`：仅放行已注册的脚本或用户白名单规则；
     * `full`：放行执行，但在需要审批时向本机 App 抛出弹窗。
3. **资源与生命周期管理**：
   * 进程组隔离（`setpgid`），超时自动杀进程组，防止子进程失控；
   * 进程孤儿 PID 文件记录，Service 重启自动清理残留。

---

## 七、分阶段实施路线与验证计划

| 阶段 | 核心目标 | 交付物 | 验收与测试标准 |
| :--- | :--- | :--- | :--- |
| **Phase 1** | **只读发现与规范加载** | 1. `SkillModels.swift`<br>2. `SkillScanner.swift`<br>3. `list_skills` & `read_skill` MCP 工具 | 单元测试验证：<br>- 成功识别 `~/.codex/skills/` 中已装 Skill<br>- 路径逃逸拒绝与尺寸超限截断<br>- MCP Inspector 调用通过 |
| **Phase 2** | **Skill 脚本安全执行** | 1. `run_skill_action` 工具接入<br>2. 接入 `BridgeDirectCommand` 进程执行器<br>3. 适配项目安全白名单与网络权限 | 单元测试验证：<br>- 执行 `agent-reach` 搜索脚本并捕获输出<br>- 安全模式拦截未授权脚本<br>- 超时熔断与孤儿清理有效 |
| **Phase 3** | **macOS App UI 状态感知** | 1. `BridgeIPC` 添加 `BridgeSkillDTO`<br>2. App 项目面板增加“已装载 Skills”展示 | App 界面实时显示项目中可用 Skills 列表及来源标签（全局/项目级） |
| **Phase 4** | **端到端闭环验证** | 1. ChatGPT Developer Mode 真实联调<br>2. 验证前端设计 Skill（`f-design`）与代码审查实际表现 | 真实 ChatGPT 网页端能自动调用 `list_skills`、读取 `read_skill` 规则并完成业务闭环 |
