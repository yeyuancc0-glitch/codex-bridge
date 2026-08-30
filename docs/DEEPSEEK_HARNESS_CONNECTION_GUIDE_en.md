# DeepSeek Harness Connection Guide

This guide describes the version-pinned DeepSeek Harness (DSH) setup supported by the current Bridge adapter. The [Chinese guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md) contains the most detailed troubleshooting and task examples.

The provider ID is:

```text
deepseek-harness
```

Omitting `provider_id` selects Codex, not DSH.

## 1. Pinned toolchain

| Component | Required value |
| --- | --- |
| Official source tag | `dsh-v0.1.1-rc.2` |
| Package version | `0.1.1-rc.2` |
| ACP protocol | `1` |
| Node | `^22.19.0` or `>=24.0.0` |
| pnpm | `11.7.0` |
| ACP SDK | `0.25.1` |

Node 22.18.x and Node 23 are not supported. Bridge validates the entry point, manifest, lockfile, Node interpreter, ACP handshake, adapter revision, and profile structure. It does not inspect Git metadata; the official tag is the source reference users should checkout to obtain the compatible package and lockfile.

## 2. Clone and build the correct entry point

Use the official [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) repository:

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness
cd deepseek-harness
git fetch --tags origin
git checkout --detach dsh-v0.1.1-rc.2

node --version
pnpm --version
pnpm install --frozen-lockfile
pnpm run build
test -f packages/examples/acp-demo/lib/bin.js
```

Register this absolute path in Bridge:

```text
<dsh-source>/packages/examples/acp-demo/lib/bin.js
```

Do not select a generic `dsh` command, `pnpm dsh web`, source TypeScript, the Web UI, or the source directory itself. Bridge executes the built ACP demo directly with Node and does not require a running terminal or browser UI.

Keep the complete source tree. Moving `bin.js` by itself removes the `package.json`, `pnpm-lock.yaml`, modules, and source-root identity that Bridge validates.

The entry point commonly uses `#!/usr/bin/env node`. Bridge resolves the real Node executable rather than treating `/usr/bin/env` as Node. A Node installation that exists only after interactive `nvm`/`asdf` shell initialization may be unavailable to the macOS LaunchAgent; the app's Probe result is authoritative.

## 3. Create an external profile

Runtime validation requires the profile to be outside the DSH source tree. For credential isolation and to prevent accidental Agent/Git access, also keep it outside task projects and the Bridge repository:

- **Required:** the DSH source tree;
- **Recommended:** every task project;
- **Recommended:** the Codex Bridge repository.

Use this layout:

```text
<dsh-profile>/
├── cordis.yml
└── .env
```

Prefer `cordis.yml` from the matching Bridge version. Final compatibility is determined by profile-structure validation and Probe.

From a Bridge source checkout:

```bash
mkdir -p /path/to/dsh-profile
cp Packages/BridgeCore/Sources/BridgeDeepSeekHarnessACP/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

From the installed app:

```bash
mkdir -p /path/to/dsh-profile
cp /Applications/CodexBridge.app/Contents/Resources/BridgeCore_BridgeDeepSeekHarnessACP.bundle/Contents/Resources/cordis.yml \
  /path/to/dsh-profile/cordis.yml
```

Do not rebuild or trim the template from an upstream generic example. It contains the validated workspace, file, shell, Web, code runtime, subagent, workflow, ACP, and execution-evidence composition. Model and effort values are the expected configurable parts; compatible trailing composition can also pass normalized structure validation. Re-Probe every change because incompatible edits cause `templateMismatch` or `needs_review`.

## 4. Configure `.env`

Create a DeepSeek API key at [DeepSeek Platform API Keys](https://platform.deepseek.com/api_keys). Store the real key only in the external profile's `.env`; never paste it into Bridge, ChatGPT, source control, screenshots, or issue reports.

From the Bridge repository:

```bash
cp Examples/DeepSeekHarnessProfile/.env.example \
  /path/to/dsh-profile/.env
chmod 600 /path/to/dsh-profile/.env
```

The current variables are:

```dotenv
DEEPSEEK_API_KEY=<fill locally>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_SEARCH_BASE_URL=https://api.deepseek.com/anthropic/v1
```

`DEEPSEEK_BASE_URL` is the Chat Completions base URL. Do not include `/chat/completions`; DSH appends it.

`DEEPSEEK_SEARCH_BASE_URL` is independent. Do not include `/messages`; DSH appends it. The endpoint must accept Anthropic Messages-compatible requests and support the native `web_search_20250305` server tool. A working main model or a generic `/messages` endpoint does not prove that Web Search works.

The packaged profile currently uses `DEEPSEEK_API_KEY` for both paths. If a custom gateway needs separate credentials, verify its support before changing the validated profile; Bridge will not read or translate credentials.

Bridge launches DSH with the profile directory as its working directory, so Harness loads the adjacent `.env` itself. Bridge does not open, persist, summarize, log, or return its contents.

## 5. Register in the app

1. Open `Connections → Local Agent Engine Connections`.
2. Click “Register Agent” and choose DeepSeek Harness.
3. Select `<dsh-source>/packages/examples/acp-demo/lib/bin.js`.
4. Continue and select `<dsh-profile>/cordis.yml`.
5. Click “Register and Probe”.
6. Review version, protocol, adapter revision, and availability.
7. When status is available, enable the installation.

Registration does not enable the provider automatically. Probe confirms local identity, compatibility, and a basic ACP session; it runs without network access and does not prove API-key validity, account credit, model execution, or Web Search.

## 6. Refresh models and defaults

1. Select the task project in Workbench.
2. Open the DeepSeek Harness execution defaults in Settings.
3. Select the installation if more than one exists.
4. Refresh the model list.
5. Select exact model IDs returned by ACP `session/new.configOptions`. Effort values come from the validated DSH Profile rather than per-model ACP advertising; the bundled thinking-enabled Profile supports `off`, `low`, `high`, and `max` with default `max`.

Do not copy model IDs or effort values from Codex, OpenCode, or Antigravity. Without an explicit user override, Bridge preserves the provider/profile current value or a saved default that remains valid.

ChatGPT/Qwen permission defaults come from `Workbench → Read Only / Write`. Project hard policy still outranks the Workbench setting and every task override.

## 7. Submit a task

Call `list_projects` and `list_agents` first. Confirm the installation is available, enabled, and accepts task submissions.

With the correct Workbench project and permission selected, the minimal task is:

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "Inspect the current project and summarize its build problem.",
  "network_access": false
}
```

Web Search, URL fetch, and external APIs require explicit network intent:

```json
{
  "provider_id": "deepseek-harness",
  "prompt": "Verify the dependency against official sources and cite them.",
  "network_access": true
}
```

Only when the user explicitly requests overrides should the client add `model_override`, exact model/Profile-supported effort values, or `permission_mode_override`. Do not pass a historical `thread_id` or Codex Supervisor fields. DSH creates a fresh session for each task; historical-session resume is not supported. `skill_name` is valid only when the user explicitly selects a discovered Bridge Skill.

Remote submissions normally enter `awaiting_local_approval`. Review project, provider, access mode, network intent, and prompt in Workbench before approving the start. Automatic remote-start approval is disabled by default and never approves later DSH permission requests or Direct operations.

Follow `get_task.wait_policy` and read terminal results from the same `get_task` snapshot: `result_summary`, `failure_code`, `changed_files`, activity, model/effort, and provider bindings. Terminal `next_action=read_final_report` is a hint string, not another MCP tool.

Queued steer sends a second prompt after the current prompt finishes. DSH also supports interrupt-current-then-continue for the active session. Neither is Codex in-flight steer.

## 8. Availability and troubleshooting

| Symptom | Check first |
| --- | --- |
| Invalid artifact | Use pinned tag and `packages/examples/acp-demo/lib/bin.js`; retain the full source tree |
| Unsupported Node | Use Node 22.19.0+ within 22.x, or Node 24+; do not use Node 23 |
| Node not found by the app | Ensure the LaunchAgent can resolve the real interpreter, not only an interactive shell alias |
| Manifest/lock missing | Do not copy `bin.js` away from its source tree |
| Profile location rejected | Runtime validation requires moving `cordis.yml` and `.env` outside the DSH source; keeping them outside task projects is also recommended |
| `templateMismatch` | Re-copy `cordis.yml` from the matching Bridge bundle |
| `needs_review` | Verify expected entry point, manifest, lock, Node, adapter, or profile replacement, then accept and Probe |
| Probe works but API auth fails | Confirm `.env` is adjacent to the registered config, the key is valid, and the main base URL is correct |
| Main model works but search fails | Check the independent search base URL, key acceptance, and `web_search_20250305` support |
| Model list is empty | Select the project and installation, refresh ACP config options, and use exact provider values |
| Write denied | Check Workbench mode, project hard policy, and the per-project write gate |
| Network denied | Set explicit `network_access=true` and satisfy project/native provider policy |
| Task waits indefinitely | Handle remote-start or runtime provider approval in Workbench |

Do not paste `.env` or raw authentication responses into support reports. Probe success is not end-to-end acceptance: validate the real model, Web Search, read-only task, write task, and permission flow with your own account and a safe test project.

## References

- [DeepSeek Harness official repository](https://github.com/deepseek-ai/deepseek-harness)
- [DeepSeek API documentation](https://api-docs.deepseek.com/)
- [DeepSeek API Keys](https://platform.deepseek.com/api_keys)
- [Detailed Chinese DSH guide](./DEEPSEEK_HARNESS_CONNECTION_GUIDE.md)
- [Detailed user guide](./USER_GUIDE.md)
