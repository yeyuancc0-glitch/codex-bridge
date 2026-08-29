import Foundation

/// A small provider-local completion contract. ACP's `end_turn` only means
/// that the current prompt became quiescent; it does not attest that the
/// requested work produced a usable result.
enum DeepSeekHarnessACPCompletionAttestation {
  enum Verdict: Equatable, Sendable {
    case missing
    case malformed
    case completed(summary: String)
    case failed(summary: String)
  }

  static let completedMarker = "<codex-bridge-result status=\"completed\"/>"
  static let failedMarker = "<codex-bridge-result status=\"failed\"/>"

  private static let markerPrefix = "<codex-bridge-result "
  private static let instruction = """

    When the requested task is finished, end your final response with exactly one standalone line:
    \(completedMarker)
    If the task cannot be completed, end with exactly one standalone line:
    \(failedMarker)
    Keep the task result concise before that line. Do not include either marker anywhere else.
    """

  static func initialPrompt(_ prompt: String) -> String {
    let suffix = instruction
    guard prompt.utf8.count + suffix.utf8.count <= 32 * 1_024 else { return prompt }
    return prompt + suffix
  }

  static let correctivePrompt = """
    Re-check the requested task and provide a concise task result. Your previous response did not
    contain a valid completion attestation. End this response with exactly one standalone line:
    \(completedMarker)
    or, if the task is not complete, \(failedMarker)
    Do not include either marker anywhere else.
    """

  static func evaluate(_ content: String) -> Verdict {
    let lines = content.components(separatedBy: .newlines)
    guard
      let index = lines.lastIndex(where: {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else {
      return .missing
    }
    let finalLine = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
    let markerCount = markerCount(in: content)
    guard markerCount <= 1 else { return .malformed }
    if finalLine == completedMarker {
      let summary = summary(before: index, lines: lines)
      return summary.isEmpty || summary.contains(markerPrefix)
        ? .malformed
        : .completed(summary: summary)
    }
    if finalLine == failedMarker {
      let summary = summary(before: index, lines: lines)
      return summary.isEmpty || summary.contains(markerPrefix)
        ? .malformed
        : .failed(summary: summary)
    }
    return content.contains(markerPrefix) ? .malformed : .missing
  }

  private static func markerCount(in content: String) -> Int {
    content.components(separatedBy: markerPrefix).count - 1
  }

  private static func summary(before index: Int, lines: [String]) -> String {
    lines[..<index]
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
