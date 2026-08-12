# Phase Accountability Ledger

状态只使用：`implemented`、`evaluated-local`、`not applicable`、`blocked`、`accepted omission`。

| Phase / artifact | Scope | Status | Decision / reason | Evidence | Verification | Remaining risk |
|---|---|---|---|---|---|---|
| Discovery response | greenfield full V1 | implemented | 用户授权代理决定 F-design 选择 | 当前目标措辞；`DESIGN.md` | design record reviewed locally | 实施中可能出现新兼容分支 |
| Delivery mode | all UI | implemented | delegated direct implementation | `DESIGN.md` | no generated references created | none |
| Reference intake | all UI | implemented | delegated no-reference | `DESIGN.md` | product plan used as project truth | native visual QA pending |
| Architecture decision | full app | implemented | plan-defined native Swift architecture | plan + `AGENTS.md` + `DESIGN.md` | external Xcode 27.0 SDK/signature/first-launch verified | beta toolchain drift |
| Product brief | full app | implemented | developer/operations tool | `DESIGN.md` | local review against V2.0 plan | outcome tests pending |
| Surface strategy | all material surfaces | implemented | per-surface task topology | `DESIGN.md` | structural convergence review | runtime data ranges pending |
| Structural exploration | greenfield | implemented | status-first shell with task workspace and connection flow overrides | `DESIGN.md` matrix | bounded-originality review | native screenshot QA pending |
| Page/state map | all material surfaces | implemented | routes, overlays and states separated | `DESIGN.md` | content canon cross-check | code not yet implemented |
| Design system/color/state | full UI | implemented | native semantic system, no parallel component library | `DESIGN.md` | contract review | code/render evidence pending |
| Component decisions | initial UI primitives | evaluated-local | native SwiftUI/AppKit selected | `DESIGN.md` register | package/runtime check pending | complex Diff may need reevaluation |
| Codex framing/initialize/models | phase 0 | implemented | isolated Swift process + LF JSON transport + dynamic catalog | `Prototypes/AppServerProbe`; versioned schema | build, 4 probe XCTest, self-test, real initialize and model/list | future Codex drift |
| Production Codex RPC foundation | phases 0/4 | implemented | one-shot process session; bounded LF transport; handshake isolation; typed initialize/models; lossless approval failure semantics; confirmed process reaping | `Packages/BridgeCore/Sources/BridgeCodexRPC` | 19 fake process/wire/lifecycle XCTest | future Codex drift and approval DTOs |
| Codex Thread/turn/steer/interrupt/Supervisor | phase 0 | implemented | stable typed wire plus isolated ephemeral read-only fixtures | `BridgeCodexRPC`; `CodexRPCFixture`; compatibility record | fake wire tests and real basic/steer/interrupt/Luna structured-output turns | write approvals and future Codex drift |
| Domain reducer foundation | phases 1/4/5 | implemented | phase/activity separation, terminal/report invariants, approvals, stop intent and recovery | `BridgeDomain` | 17 reducer XCTest | public event wire schema remains internal/versioned |
| Persistence foundation | phases 1/4 | implemented | GRDB CAS event append, durable idempotency claims and atomic dual locks | `BridgePersistence` | 6 SQLite behavior XCTest, including cross-connection contention | release/retention and higher-level projections pending |
| Secure project read boundary | phases 1/5 | implemented | component-aware containment, sensitive policy, descriptor-relative no-follow open and identity recheck | `BridgeSecurity` | 7 path/symlink/replacement/binary/limit XCTest | search layer and secure write adapter pending |
| Project registry foundation | phases 1/5 | implemented | opaque IDs, exact canonical root/worktree identity, forward-compatible permission decoding and path-free MCP summaries | `BridgeProjects` | 10 registry/root/worktree/DTO/decoding XCTest | GRDB repository and UI registration pending |
| Deterministic policy foundation | phase 5 | implemented | project permissions are hard upper bounds; fixed executable identity, exact argv, forbidden-path glob and scoped limits | `BridgePolicy` | 8 command/file policy XCTest | authoritative approval correlation, secure write adapter and persistence pending |
| Project-bound Codex execution | phases 1/4 | implemented | only Registry-issued exact roots can start read-only Threads; response cwd is rechecked before binding | `BridgeExecution` | 3 state/binding XCTest | durable binding repository and workspace-write flow pending |
| Local read-only MCP | phase 2 | implemented | strict per-session SDK servers behind a secret-path IPv4 loopback NIO listener; only five bounded read tools | `BridgeMCP`; `docs/MCP_SWIFT_SDK_INTEGRATION.md` | 30 tool/session/HTTP/in-memory and real pinned-SDK loopback XCTest including cancellation, dropped-POST retirement and same-session SSE resume; Inspector 2.1.0 fixture gate | slow-reader pressure, Keychain composition and real Tunnel Host/Origin pending |
| Secure MCP Tunnel | phase 3 | blocked | helper dependency and supply-chain contract evaluated; process integration not started | `docs/DEPENDENCIES.md`; V2.0 plan | official release/hash audit only | helper lifecycle, Runtime Key, doctor/readyz, ChatGPT Developer Mode and reconnect pending |
| Execution/Supervisor | phases 4/6 | blocked | read-only project binding and live protocol fixtures exist; full coordinator not started | `BridgeExecution`; plan | full isolated task/recovery required | approvals, usage/rate limits and report pipeline |
| Native UI | phases 1/7 | blocked | implementation not started | external Xcode verified | App build/UI test required | system xcode-select needs user password; wrapper works |
| Motion coverage | native UI | blocked | matrix drafted, code absent | `DESIGN.md` | normal/reduced capture | UI implementation required |
| Media transitions | no media-led surfaces | not applicable | V1 is evidence-led native tool | `DESIGN.md` | contract review | none |
| Browser/mobile QA | native macOS only | not applicable | replaced by native window/a11y matrix | V2.0 plan + `DESIGN.md` | native matrix pending | full Xcode required |
| Packaging/release | phase 7 | blocked | no app bundle/signing yet | plan | xcodebuild/sign/notary/Gatekeeper | Apple signing credentials external |

Update this ledger whenever code or runtime evidence changes a status. `blocked` here describes an artifact state, not the overall goal status.
