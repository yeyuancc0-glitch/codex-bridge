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
| Production Codex RPC foundation | phases 0/4 | implemented | one-shot process session; bounded LF transport; typed initialize/models; lossless approval failure semantics | `Packages/BridgeCore/Sources/BridgeCodexRPC` | fake process concurrency, fragmentation, timeout, cancellation, exit, contamination, overflow and lifecycle tests | typed Thread/Turn methods and real fixture pending |
| Codex Thread/turn/steer/interrupt/Supervisor | phase 0 | blocked | real isolated fixture not implemented yet | compatibility record | Fake then real read-only fixture required | experimental behavior and Codex quota |
| Domain reducer foundation | phases 1/4/5 | implemented | phase/activity separation, terminal/report invariants, approvals, stop intent and recovery | `BridgeDomain` | 17 reducer XCTest | public event wire schema remains internal/versioned |
| Persistence foundation | phases 1/4 | implemented | GRDB CAS event append, durable idempotency claims and atomic dual locks | `BridgePersistence` | 6 SQLite behavior XCTest, including cross-connection contention | release/retention and higher-level projections pending |
| Secure project read boundary | phases 1/5 | implemented | component-aware containment, sensitive policy, descriptor-relative no-follow open and identity recheck | `BridgeSecurity` | 7 path/symlink/replacement/binary/limit XCTest | ProjectRegistry and search layer pending |
| Local MCP/Tunnel | phases 2/3 | blocked | implementation not started | plan | Inspector/ChatGPT required | SDK/helper drift |
| Execution/Supervisor | phases 4/6 | blocked | implementation not started | plan | real isolated task required | usage/rate limits |
| Native UI | phases 1/7 | blocked | implementation not started | external Xcode verified | App build/UI test required | system xcode-select needs user password; wrapper works |
| Motion coverage | native UI | blocked | matrix drafted, code absent | `DESIGN.md` | normal/reduced capture | UI implementation required |
| Media transitions | no media-led surfaces | not applicable | V1 is evidence-led native tool | `DESIGN.md` | contract review | none |
| Browser/mobile QA | native macOS only | not applicable | replaced by native window/a11y matrix | V2.0 plan + `DESIGN.md` | native matrix pending | full Xcode required |
| Packaging/release | phase 7 | blocked | no app bundle/signing yet | plan | xcodebuild/sign/notary/Gatekeeper | Apple signing credentials external |

Update this ledger whenever code or runtime evidence changes a status. `blocked` here describes an artifact state, not the overall goal status.
