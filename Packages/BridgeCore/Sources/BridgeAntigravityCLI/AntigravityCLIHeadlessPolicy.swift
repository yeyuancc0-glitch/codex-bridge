import Foundation

enum AntigravityCLIHeadlessPolicy {
  static func prompt(_ prompt: String) -> String {
    prompt
  }

  static func permissionDeniedSummary(permissionMode: String?) -> String {
    let mode = permissionMode ?? "unknown"
    return
      "Antigravity could not run a requested tool in headless mode (permission_mode=\(mode)). The provider response was preserved, but the task is incomplete. In Antigravity CLI settings, choose Tool Execution Policy 'proceed-in-sandbox' (recommended) or another non-interactive policy you explicitly trust, then retry. Bridge preserves agy's native tools and sandbox and does not silently change shared settings."
  }
}
