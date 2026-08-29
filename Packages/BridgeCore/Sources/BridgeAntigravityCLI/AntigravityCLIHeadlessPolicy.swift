import Foundation

enum AntigravityCLIHeadlessPolicy {
  private static let instruction = """

    This is a non-interactive Codex Bridge run. Do not wait for or request interactive approval. Work only within the provided workspace and Antigravity's native sandbox. Prefer Antigravity's native file, search, and web tools over shell commands. Do not run a shell command merely to discover or validate a native search or web tool; use the native tool directly. Shell commands may be denied in headless mode; if one is denied, continue with an equivalent native operation when possible and state the blocked step explicitly. Do not claim that a denied command ran or that the task is fully complete.
    """

  static func prompt(_ prompt: String) -> String {
    guard prompt.utf8.count + instruction.utf8.count <= 32 * 1_024 else { return prompt }
    return prompt + instruction
  }

  static func permissionDeniedSummary(permissionMode: String?) -> String {
    let mode = permissionMode ?? "unknown"
    return
      "Antigravity could not run a requested tool in headless mode (permission_mode=\(mode)). The provider response was preserved, but the task is incomplete. Configure a narrow allow-rule for the reported action before retrying. For sandboxed shell commands, agy's native toolPermission=proceed-in-sandbox is supported; Bridge does not modify shared settings."
  }
}
