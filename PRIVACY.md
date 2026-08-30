# Privacy

Codex Bridge is a local-first macOS application. The project does not operate a developer cloud service, telemetry collector, analytics endpoint, account database or billing system.

## Data stored on the Mac

The app stores task events, project registrations, non-secret connection profiles, bounded Git/verification/report evidence and lifecycle preferences in `~/Library/Application Support/CodexBridge`. Database files are created with `0600` permissions inside a `0700` directory. Connection credentials and Tunnel Runtime Keys are stored in the user's Keychain, not in the databases or logs.

Registered project source remains in its existing location. Codex Bridge does not copy whole projects into its data directory.

## Data sent outside the Mac

- Codex execution and any enabled Supervisor use the user's own Codex ChatGPT session through the local `codex app-server`. Prompts and evidence required for those operations are therefore processed by the user's configured Codex service.
- ChatGPT receives only structured MCP results for tools the user has enabled and invoked. Project roots, arbitrary absolute paths, raw credentials and unrestricted file contents are not exposed by the MCP contract.
- Secure Tunnel mode sends transport traffic through the pinned OpenAI tunnel helper. The restricted Runtime Key is used only by that helper and is not sent to Codex or included in task evidence.
- Manual HTTPS mode contacts only the endpoint explicitly configured by the user.

Codex Bridge does not add an independent analytics or crash-reporting transmission path.

## Logs and support bundles

Runtime logs are bounded and redact recognized credentials and absolute local paths. Support bundles are generated only after an explicit local action. They contain typed diagnostic facts rather than raw project files, process output, credentials, endpoint URLs or authentication material. Users should still review a support bundle before sharing it.

## Permissions and control

Project access is limited to directories registered by the user. Network and write capabilities default to denied or require a local decision. Codex approval remains deny-only when the upstream protocol cannot provide authoritative, atomically enforceable operation evidence.

Users can remove the app and delete `~/Library/Application Support/CodexBridge` to remove its local databases and evidence. Keychain items named for Codex Bridge must be removed separately in Keychain Access. Deleting app data does not delete registered projects or Codex account data.
