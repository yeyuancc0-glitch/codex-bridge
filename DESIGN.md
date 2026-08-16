# Codex Bridge Product Design System

## Overview

Codex Bridge 是一个原生 macOS 开发者工具。它连接 ChatGPT 网页版、本机 Codex app-server、只读 Supervisor（默认推荐 Luna）、项目白名单和本地审批。界面的成功标准不是“看起来像 AI 产品”，而是让用户在高风险、长时运行的开发任务中快速回答四个问题：连接是否健康、Codex 正在做什么、是否需要我决定、结果是否有证据。

本文件是设计与页面契约；方案文档定义产品能力，Swift 代码中的语义 Token 与原生组件是可执行真相。

## Product Brief

**Product class:** 原生 developer/operations tool，包含 onboarding 与高风险审批 bounded flow。

**Primary audience and context:** 同时使用 macOS、ChatGPT 网页版和 Codex 的个人开发者；可能在多个项目和 Thread 间切换，并让长任务后台运行。

**Primary job:** 安全地把已确认任务交给正确的本机 Codex Thread，持续理解执行与监督状态，并在必要时本机批准、纠偏或中断。

**Success event:** ChatGPT 提交的结构化任务在用户授权项目中完成，验证与独立 Supervisor 结论被保存为可回读的最终报告。

**Success measures:**

- Effectiveness：项目、Thread、模型、权限和任务契约正确绑定；任务可完成并产生可信报告。
- Efficiency：首次连接流程有清楚进度；日常状态无需钻入日志；审批包含足够上下文。
- Errors/recovery：断线、崩溃、限流、验证失败和权限拒绝均有明确恢复路径，输入与历史不丢失。
- Confidence：每个状态均有来源、时间和下一步；颜色之外还有图标与文本；事实来自事件、Git 和退出码。

**Business outcome:** 形成可由个人自托管和审计的开源工具，不运营开发者云端。

**Surface register:** 全部为克制的 Product Surface；Onboarding 允许较低密度和更强引导，但不是品牌/营销页。

**Core content/data:** 连接健康、Codex 账户/版本/模型能力、项目权限、Thread、任务契约、事件、命令、文件、Diff、审批、验证、Supervisor 决策、最终报告和设置。

**Scope and fidelity:** V1 完整原生 macOS 应用，遵循方案全部 V1 要求；Beta 诚实标注实验性 app-server 风险。

**Platforms and inputs:** macOS 14+；键盘、指针、VoiceOver、系统浅/深色、Reduced Motion、Increase Contrast；无 iOS/Windows/Linux UI。

**Visual calibration:** Expressive variance low；information density balanced-to-high，按页面任务调整；motion energy low/functional。

**Must preserve:** 原生行为、安全边界、状态可解释性、菜单栏常驻、窗口关闭后后台运行、系统主题与可访问性。

**Must avoid:** 通用 AI 渐变、玻璃拟态、装饰性卡片墙、假指标、纯颜色状态、无证据“成功”、阻碍高频任务的过场动画。

**Assumptions and unresolved risks:** 外置完整 Xcode 27.0 Beta 5 可通过项目包装脚本使用，但系统级 `xcode-select` 尚未切换；Codex app-server 与 Swift MCP SDK 均可能变化；Tunnel helper 的固定版本与签名需要实施期官方证据。

## Design Delivery Mode Record

- Mode selected: delegated -> design package -> direct implementation.
- Pages/states using generated references: 无。
- Pages/states implemented directly: 全部原生页面与菜单栏。
- Design Package approval point: 用户已明确授权所有 F-design 选择由代理决定；本文件落盘后可进入实现。
- Generated artifacts required: 无。
- Artifacts explicitly skipped: 页面生成参考图、参考图 manifest、桌面/移动生成图 parity、reference-to-code 图像比对。
- Fidelity target for user-supplied references: 无外部参考。
- Verbatim authorization: “skill中需要问用户的都由你定不用问我”。

## Reference Intake Record

- Mode: delegated no-reference。
- Source: 产品 V2.0 方案、macOS 原生平台惯例、真实运行状态。
- Emulate: 原生控制层级、系统设置的可访问性与清楚的开发工具证据表达。
- Avoid: 复制其他产品品牌、专有资产或营销文案。
- Motion/media evidence: 无外部视频或图像证据；不发明叙事动效。
- Rights/access limits: 只使用系统 SF Symbols 和项目自有资源。

## Architecture Decision Record

- Experience architecture: task-focused native app shell；首次使用为线性 Onboarding；日常使用为状态/队列入口与对象详情；高风险决定使用本机 Sheet。
- Technical architecture: Swift 6 + SwiftUI/AppKit + SPM；领域与基础设施拆成 BridgeCore modules；状态经 actor/事件存储单向投影到 `@MainActor` UI。
- Selection: 用户委托；方案已明确技术栈和模块边界。
- Consequences: 原生系统集成与安全能力强；首期仅 macOS；完整发布需要 Xcode 与 Apple 签名链。
- Rejected alternatives: Electron/Tauri 会形成第二前端运行时并偏离方案；云控制台违反本地优先；纯菜单栏不足以承载任务证据与审批。

## Surface Strategy Record

| Surface | Class | Primary job / success | Core objects | Topology and first priority | Compact-window change | Constraints | Exploration |
|---|---|---|---|---|---|---|---|
| Onboarding | bounded flow | 完成可用且安全的首次连接 | 检测、登录、Transport、项目、策略、测试 | 单列分步，当前阻断与下一步置顶 | 保持单列，底部操作不遮挡内容 | 可恢复、凭证不回显 | required |
| Overview | monitoring/triage | 10 秒内判断是否健康及是否需处理 | connection、Codex、运行任务、审批、告警 | 状态路径 + 需处理队列 + 最近活动 | 隐藏次要诊断列，保留待处理和运行任务 | 不制造聚合指标 | required |
| Tasks | operations queue | 找到并继续/检查任务 | 状态、项目、Thread、模型、时间 | 可筛选列表，详情按导航打开 | 单列表，选择后导航详情 | 大量历史需分页 | required |
| Task detail | evidence workspace | 理解、控制并验收一个任务 | 契约、timeline、commands、files、diff、supervision、verification | 顶部控制条 + 证据型 tabs；当前状态和中断始终可见 | tabs 进入溢出菜单，关键摘要先行 | 长日志/Diff，终态只读 | required |
| Projects | registry/settings | 管理白名单与项目级权限 | 路径、Git、权限、命令、限制 | 项目列表 + Inspector/详情 | 选择后推入详情 | 外置盘离线、dirty | required |
| Threads | retrieval | 按项目找到真实 Thread | ID、preview、cwd、source、time、busy | 项目筛选 + 高密度表/列表 | 降为两行列表 | 不能按标题猜绑定 | required |
| Approvals | high-stakes queue | 在足够证据下允许或拒绝 | source、command/file、cwd、reason、risk | 待审批优先队列；详情 Sheet | 全屏 Sheet，决策固定底部 | 本机唯一决策边界 | required |
| Connections | configuration/diagnosis | 建立并修复 ChatGPT transport | mode、endpoint、helper、health、errors | 模式选择 + 真实连接链路 + doctor | 单列 progressive disclosure | Key 不回显 | required |
| Logs | investigation | 查明错误并导出脱敏证据 | timestamp、source、severity、message | 可筛选日志表 + detail | 简化列，detail 导航 | 默认无文件全文/diff | not required: 标准日志检索结构适配任务 |
| Settings | settings | 修改全局安全和保留策略 | startup、notifications、retention、defaults | 原生分组 Form | 原生 Form 自适应 | 高级危险项明确解锁 | not required: macOS Settings 结构有成熟惯例 |
| Menu bar | glance/quick control | 看状态、打开窗口、暂停新任务 | connection、running、approvals | 单层短菜单，状态在首项 | n/a | 不承载复杂审批 | not required: NSStatusItem 惯例 |

## Structural Direction Record

探索过三种真实结构：

| Axis | A 状态优先控制台（selected） | B 任务工作台优先 | C 连接设置优先 |
|---|---|---|---|
| Governing idea | 先回答系统是否可用、哪里需处理 | 启动后直接进入最近任务 | 连接链路是整个应用的首页 |
| Primary path | Overview -> approval/task -> evidence | Tasks -> selected detail -> controls | Connection -> diagnostics -> feature routes |
| IA | 按 Overview、work queues、registries、diagnostics 分区 | Tasks 成为顶级根，其余为辅助 | Connection/Setup 成为根，任务二级 |
| First viewport | 健康链路、待处理、运行任务 | 最近任务时间线和控制 | Tunnel/Codex/MCP 步骤和配置 |
| Object relationship | 多信号 triage 后进入单对象 | 单任务对象持续占据主区 | transport 状态组织其他能力 |
| Benefit | 日常最短判断路径，风险和审批不遗漏 | 高频只做一个任务时更快 | 初次配置和故障排查最直观 |
| Cost/risk | Overview 必须避免卡片墙和假指标 | 容易隐藏全局断线/审批 | 日常使用被低频配置主导 |

选择 A，因为日常主任务既包含“执行任务”也包含“确认连接/审批是否阻断”；Overview 只展示可行动事实，不展示装饰指标。Task detail 内部采用 B 的证据工作台。Onboarding 与 Connection 采用 C 的明确连接链路。这是按 surface 选择，不把三种结构平均混合。

Bounded originality：保留 macOS Sidebar、Table、Form、Sheet 与 Toolbar 惯例；唯一签名结构是“真实连接路径状态轨”，每个节点对应可验证组件和恢复动作，不是装饰流程图。

## Page And State Map

| Page/state | Entry | Primary action | Required states | Completion |
|---|---|---|---|---|
| Onboarding | 首次启动/未配置 | 继续当前步骤 | checking、ready、blocked、error、offline、restored | 本地 MCP 与选定 transport 测试成功且至少一个项目登记 |
| Overview | 日常启动/菜单栏 | 处理最高优先问题 | all-ready、degraded、disconnected、approval waiting、task running、empty-first-use | 用户理解状态并进入正确对象 |
| Task list | Sidebar | 打开/筛选任务 | loading、empty-first-use、empty-filter、stale、error、large history | 定位任务 |
| Task detail | list/notification/deep link | 中断、审批或读取报告 | all task states、partial event failure、long content、terminal read-only | 当前状态和下一步明确 |
| Project list/detail | Sidebar/onboarding | 添加或修改项目 | no projects、offline volume、dirty Git、invalid path、read-only | 权限保存且验证 |
| Thread list/detail | Sidebar/project | 继续或在 Codex 打开 | loading、empty、busy、cwd mismatch、unsupported source | 精确 Thread 被选中 |
| Approval queue/sheet | notification/task | Allow once / deny | expired、policy blocked、waiting、responding、resolved | 决定持久化并发送给正确 turn |
| Connection | Sidebar/onboarding | Test/repair connection | stopped、starting、authenticating、connecting、ready、degraded、failed | 真实 MCP initialize/tools 检查通过 |
| Logs | Sidebar/error link | 筛选/导出支持包 | empty、streaming、large、export success/error | 找到诊断或生成脱敏包 |
| Settings | Sidebar/app menu | 保存设置 | default、dirty、validation error、saved | 设置持久化并生效 |

Dialogs/popovers are bounded decisions, not routes: task confirmation Sheet、Codex approval Sheet、project picker、model/effort picker、dangerous-setting confirmation、menu-bar popover/menu。

## Page Content Canon

- Product name: Codex Bridge；Beta 标记仅在关于页、首次连接和兼容警告出现。
- Global navigation IDs: `overview`, `tasks`, `projects`, `threads`, `approvals`, `connections`, `logs`, `settings`。
- Connection node IDs: `chatgpt`, `tunnel`, `localMCP`, `executionCodex`, `supervisorCodex`；只展示真实健康数据。
- Task evidence tab IDs: `summary`, `timeline`, `commands`, `files`, `diff`, `supervision`, `verification`, `logs`。
- Core actions: `Start task`, `Reject`, `Run read-only`, `Interrupt`, `Open in Codex`, `Test connection`, `Pause new tasks`；中文版使用一致、结果导向的本地化文案。
- IDs、路径、模型、effort、分支、退出码与时间均来自真实数据，不在 UI 里构造示例值用于发布。
- Compact window 允许折叠诊断细节、缩短列和把 Inspector 推入导航；不能移除审批后果、任务目标、状态、主操作或恢复说明。

## Product Character And Surface Registers

- Voice: precise、calm、accountable。
- Physical scene: 一张安静的开发工作台，连接指示灯、任务清单和审计记录各司其职，没有装饰性仪表。
- Subject-world inventory: 连接节点、Thread、事件序列、Git diff、命令退出码、审批票据、检查点、日志游标、项目根目录。
- Signature motif: 可验证的 connection path status rail；节点状态变化保持空间连续，但不闪烁或循环吸引注意。
- Anti-references: AI SaaS 营销首页、霓虹控制台、卡片墙、游戏化进度、拟物终端噪声。

## Colors And Contrast

精确值由 Swift `BridgeTheme` 语义映射管理，优先使用系统动态颜色。

| Role | Intent | Native mapping direction |
|---|---|---|
| canvas | 主窗口背景 | window/background system color |
| surface | 列表、表单和详情工作区 | control/background system material without decorative blur |
| elevatedSurface | Sheet、Popover、菜单 | platform-provided elevated material |
| textPrimary / Secondary | 主信息/辅助元数据 | label / secondaryLabel |
| separator | 分组和列边界 | separator/quaternary fill |
| actionPrimary | 当前主要安全动作 | system accent，受用户 Accent Color 影响 |
| focus | 键盘焦点 | system focus ring，不用自绘低对比边框替代 |
| selection | 当前列表/Tab 选择 | system selection + text/icon indicator |
| statusInfo | 中性信息/运行 | blue semantic role + icon/text |
| statusSuccess | ready/completed | green semantic role + checkmark/text |
| statusWarning | degraded/waiting | orange semantic role + warning icon/text |
| statusError | failed/blocked | red semantic role + error icon/text |
| destructive | interrupt/remove/reject | destructive role，明确动词与确认 |
| disabled | unavailable | system disabled behavior，仍可读并解释原因 |

Salience budget：窗口大部分为系统 canvas 和安静工作区；强调色只用于当前主操作、选择和焦点；状态色局限于真实状态节点与相应说明。

### Theme Matrix

| Role | Light | Dark | Increased contrast |
|---|---|---|---|
| canvas/surface | 系统浅色层级 | 系统深色独立层级，非反相 | 使用系统增强边界 |
| text | label roles | label roles | 不降低辅助文本至不可读 |
| separator | 低权重清楚分隔 | 重新映射而非复制浅色 alpha | 加强边界 |
| status/action | 系统语义色 | 系统深色语义色 | 文本、图标、形状继续承载含义 |
| focus/selection | 原生焦点/选择 | 原生焦点/选择 | 保持明显且不依赖 hue |

## Typography

- 全部产品 UI 使用系统字体；代码、Thread ID、相对路径、命令和哈希使用系统 monospaced role。
- 使用 SwiftUI semantic text styles，支持系统文字大小；不设置负 tracking，不使用全大写装饰标签。
- 页面标题、section heading、body、caption、monospaced evidence 五类角色足够；数字对齐时使用 monospaced digits。
- 长任务契约和报告正文限制可读行宽；Diff/日志允许横向代码滚动但页面本身不横溢。

## Layout, Grid, Spacing, And Density

- 主窗口使用 `NavigationSplitView`；目标默认宽度 1180×760，合理最小宽度由实现和真机 QA 决定。
- 8pt 逻辑间距基线，紧密元数据可用 4pt，主要 section 间用 16/24pt；精确值在 `BridgeTheme`。
- 高密度表与日志保持稳定列对齐；次要列在 compact window 变为 detail 行，而非无限压缩。
- Task detail 顶部 control/status bar 稳定，证据区域使用 tabs/toolbar；不用把完整工具嵌入装饰卡片。

## Shape, Elevation, And Section Grammar

- 原生控件遵循平台 shape；自定义独立对象边界半径不超过 8pt。
- 卡片仅用于真正独立、具有状态/动作/生命周期的对象；不嵌套卡片。
- 页面分区首选 header、alignment、divider、list/table、grouped form 和 inspector。
- Elevation 只表达 Sheet/Popover/Menu/拖拽关系；主内容不漂浮。

## Components And States

### Component State Matrix

| Component | Default | Focus/hover/pressed | Selected/expanded | Disabled/loading | Error/success |
|---|---|---|---|---|---|
| Buttons | outcome label + role | 原生指针/按压/焦点 | n/a | 稳定尺寸，说明不可用原因/进度 | destructive 单独角色；结果用 status region |
| Sidebar/list row | label + optional count/status | 原生 row feedback | selection background + persistent content cue | row 不因后台刷新跳动 | inline icon/text + recovery link |
| Text field/secure field | persistent label | 原生 focus ring | n/a | read-only 与 disabled 区分 | field message 关联并保留输入 |
| Picker/segmented | current value | 原生交互 | check/selection shape + label | unsupported effort 不显示或解释 | stale catalog 明确提示刷新 |
| Status node | icon + label + timestamp | actionable node 可聚焦 | current diagnostic target 有 selection | checking 使用 progress + text | ready/warning/error 均有非颜色信号 |
| Timeline event | source + kind + time | row action 可聚焦 | expanded 显示证据 | incremental loading 保持游标 | severity icon/text，失败有下一步 |
| Approval sheet | source/effect/risk | 键盘完整流 | selected decision 清楚 | responding 防重复 | expired/blocked 不提供无效 allow |
| Diff/log evidence | semantic text | find/copy controls 可聚焦 | active file/filter 清楚 | paged loading | parse/export error 保留可恢复上下文 |

## Icons And Imagery

- 使用 SF Symbols；同一语义保持同一 symbol，不手绘替代已有系统图标。
- 图标不能独立承担陌生动作，icon-only control 有 accessibility label 与 help tooltip。
- V1 无营销图像、3D 或装饰插画。真实项目图标、Diff、时间线和连接节点就是产品证据。

## Motion And Interaction

- Motion energy: low / functional。
- Timing family: 120–180ms 直接反馈，180–240ms panel/disclosure continuity；长任务进度由真实异步状态驱动，不用无限装饰脉冲。
- 只动画 opacity/transform 或原生可高效属性；不使用 `transition: all` 概念对应的全属性隐式动画。
- Connection rail：节点状态变更使用一次性 symbol/opacity transition；断线或错误停止动画并显示静态恢复动作。
- Sheet、Inspector、Disclosure、Tab 采用系统连续性；高频键盘动作无额外编排。
- Reduce Motion：取消移动/缩放，状态立即切换；进度仍通过文本和系统 ProgressView 表达。

### Motion Coverage Matrix (initial)

| Event | Category | Implementation | Reduced motion | Status |
|---|---|---|---|---|
| button/toggle/selection/focus | direct feedback | native SwiftUI/AppKit state feedback | native immediate | proposed |
| Sheet/Inspector/disclosure/tabs | overlay/state continuity | platform transition, only where it preserves context | instant/fade | proposed |
| process/connection/task progress | async | ProgressView + text + timestamp; finite status transition | same semantic status, no movement | proposed |
| Sidebar/detail navigation | navigation/layout | NavigationSplitView native continuity | platform reduced behavior | proposed |
| media | media transition | not applicable: no media-led surface | n/a | not applicable |
| brand sequence | narrative | not applicable: task product with no brand surface | n/a | not applicable |

## Responsive And Compact-Window Composition

产品不支持 mobile viewport；F-design 的 mobile parity 以 macOS compact-window 与大字号重排验证替代，原因是 V1 平台明确仅 macOS。

- Desktop wide：Sidebar + content + optional Inspector；证据表保留关键列。
- Medium：Inspector 收入 toolbar/sheet；表格隐藏非关键列。
- Compact：Sidebar collapse；list 和 detail 使用导航推进；审批 Sheet 占主窗口；主操作与状态不可隐藏。
- Large text/200% equivalent：允许 section 纵向扩展，避免固定高度截断；工具条把次要动作放入 menu。
- Menu bar：只保留状态、运行任务、审批计数、打开、暂停和退出。

## Design System Governance

| Concern | Canonical source | Consumers | Verification |
|---|---|---|---|
| semantic tokens | `UI/DesignSystem/BridgeTheme.swift` | all UI | light/dark/contrast snapshots and inspection |
| component mappings | `UI/DesignSystem/Components/` | feature views | state/keyboard/VoiceOver tests |
| navigation/content IDs | domain types + this content canon | Sidebar, menu bar, deep links | unit + UI navigation tests |
| motion policy | `BridgeMotion.swift` + this file | status, overlays, navigation | normal/reduced-motion capture |
| design documentation | `DESIGN.md` | all contributors | phase ledger review |

- Primitive -> semantic -> component dependency only。
- Surface override 必须有具体任务理由；重复三次且语义相同才评估提升为共享模式。
- 共享 Token 或组件变更必须检查 Overview、Task detail、Approval 和 Connection 四个代表 consumer。
- 公共契约默认兼容；breaking change 需要迁移说明和变更记录。

## Component Decision Register (initial)

| Need | Existing evidence | Search trigger | Decision | Reason/adaptation | Verification |
|---|---|---|---|---|---|
| NavigationSplitView, List/Table, Form, Button, Toggle, Picker, ProgressView | macOS SwiftUI platform | no | existing/native | 原生行为、主题、键盘和 VoiceOver 风险最低 | UI tests + manual accessibility |
| Sheet, Menu, Popover, Inspector | SwiftUI/AppKit | accessibility-heavy but platform owns behavior | existing/native | 避免引入第二套 focus/overlay 系统 | focus restoration, Escape, VoiceOver |
| Menu bar | AppKit `NSStatusItem` | platform-specific | existing/native | 方案要求且平台原生 | menu behavior + background lifecycle |
| Diff viewer | no project component | large text/evidence behavior | local AppKit wrapper initially | V1 先实现安全分页与 monospaced display；复杂编辑器不是目标 | huge diff, copy, keyboard, accessibility |
| Timeline/log virtualization | native lazy containers/table | large collections | existing/native initially | 先用分页+lazy rendering，数据证明不足时再研究专用组件 | 10k fixture, memory/profile |
| Icons | SF Symbols | no | existing/native | 平台一致且无需额外许可包 | symbol availability + labels |

Infrastructure packages such as GRDB, swift-log and MCP Swift SDK are not UI component decisions; their versions, licenses and health belong to dependency evidence before integration.

## Do And Do Not

Do:

- 显示事实来源、时间、错误原因和下一步。
- 把等待用户的审批和风险置于比“最近完成”更高的位置。
- 让终态报告只读且可追溯到事件、Git 和验证。
- 对非关键区域局部失败，不阻断整个窗口。

Do not:

- 用绿色点替代“Ready / last checked / endpoint”文字。
- 把 Overview 做成均匀统计卡片墙。
- 在审批中隐藏 cwd、命令 argv、请求来源或影响范围。
- 自动回显 Runtime Key，或在示例/截图中填入真实凭证。
- 用动画暗示任务仍在运行，除非真实状态如此。

## Known Gaps And Approved Exceptions

- Generated page references: explicitly skipped by direct mode。
- Browser matrix: not applicable to native macOS UI；替换为真实 App 运行、窗口尺寸、主题、VoiceOver、Reduced Motion、Increase Contrast 和 UI Test 证据。
- Mobile parity: not applicable to V1 platform；compact-window 和大字号重排仍必须验证。
- Full App visual verification: Xcode 已验证完整，待 App 工程与可运行 UI 形成后执行。
