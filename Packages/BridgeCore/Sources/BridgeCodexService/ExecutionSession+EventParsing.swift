import BridgeCodexRPC
import BridgeDomain
import BridgeSecurity
import Crypto
import Foundation

extension ExecutionSession {
  func parseItem(_ params: JSONValue?) -> (key: CodexApprovalItemKey, type: String)? {
    guard let object = params?.objectValue,
      let threadID = object["threadId"]?.stringValue,
      let turnID = object["turnId"]?.stringValue,
      let item = object["item"]?.objectValue,
      let itemID = item["id"]?.stringValue,
      let type = item["type"]?.stringValue,
      Self.isSafeWireIdentifier(threadID),
      Self.isSafeWireIdentifier(turnID),
      Self.isSafeWireIdentifier(itemID),
      !type.isEmpty,
      type.utf8.count <= 64,
      !type.contains("\0")
    else {
      return nil
    }
    return (
      CodexApprovalItemKey(threadID: threadID, turnID: turnID, itemID: itemID),
      type
    )
  }

  static func semanticSourceID(_ source: JSONValue?) throws -> String {
    guard let source else {
      throw ExecutionServiceError.protocolViolation("semantic source")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return SHA256.hash(data: try encoder.encode(source)).map {
      String(format: "%02x", $0)
    }.joined()
  }

  static func agentMessages(from turn: CodexTurn) -> [ExecutionAgentMessage] {
    var messages: [ExecutionAgentMessage] = []
    for item in turn.items {
      guard let object = item.objectValue, let itemID = object["id"]?.stringValue else { continue }
      switch object["type"]?.stringValue {
      case "agentMessage":
        guard let text = object["text"]?.stringValue,
          let message = try? ExecutionAgentMessage(
            key: "agent:" + itemID,
            role: .agent,
            kind: .agent,
            content: OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 256 * 1_024)
          )
        else { continue }
        messages.append(message)
      case "reasoning":
        let content = reasoningContent(from: object)
        guard
          let message = try? ExecutionAgentMessage(
            key: "reasoning:" + itemID,
            role: .agent,
            kind: .reasoning,
            content: OutboundContentSecurity.redacted(content, maximumUTF8Bytes: 256 * 1_024)
          )
        else { continue }
        messages.append(message)
      case "mcpToolCall", "dynamicToolCall":
        guard let tool = object["tool"]?.stringValue,
          let statusValue = object["status"]?.stringValue,
          let status = ExecutionToolCallStatus(rawValue: statusValue)
        else { continue }
        let arguments = encodedArguments(object["arguments"])
        let safeTool = OutboundContentSecurity.redacted(tool, maximumUTF8Bytes: 256)
        let content = arguments ?? safeTool
        guard
          let message = try? ExecutionAgentMessage(
            key: "tool:" + itemID,
            role: .agent,
            kind: .toolCall,
            content: content,
            toolName: safeTool,
            toolStatus: status.rawValue,
            toolArguments: arguments
          )
        else { continue }
        messages.append(message)
      default:
        continue
      }
      if messages.count >= 256 { break }
    }
    return messages
  }

  static func toolCall(from params: JSONValue?) -> ExecutionToolCall? {
    guard let object = params?.objectValue,
      let item = object["item"]?.objectValue,
      let itemID = item["id"]?.stringValue,
      let type = item["type"]?.stringValue,
      type == "mcpToolCall" || type == "dynamicToolCall",
      let tool = item["tool"]?.stringValue,
      let statusValue = item["status"]?.stringValue,
      let status = ExecutionToolCallStatus(rawValue: statusValue)
    else {
      return nil
    }
    return try? ExecutionToolCall(
      itemID: itemID,
      tool: OutboundContentSecurity.redacted(tool, maximumUTF8Bytes: 256),
      arguments: encodedArguments(item["arguments"]),
      status: status
    )
  }

  private static func encodedArguments(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    if case .null = value { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8),
      !text.isEmpty
    else {
      return nil
    }
    return OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 64 * 1_024)
  }

  private static func reasoningContent(from object: [String: JSONValue]) -> String {
    var parts: [String] = []
    if case .array(let content)? = object["content"] {
      for part in content {
        if let text = part.stringValue, !text.isEmpty {
          parts.append(text)
        }
      }
    }
    if case .array(let summary)? = object["summary"] {
      for part in summary {
        if let text = part.stringValue, !text.isEmpty {
          parts.append(text)
        }
      }
    }
    return parts.joined(separator: "\n")
  }

  static func turnFailureSummary(_ turn: CodexTurn) -> String {
    let base = "Codex reported that the Turn failed."
    guard let error = turn.error?.objectValue else { return base }
    let message = error["message"]?.stringValue ?? ""
    let info = error["codex_error_info"]?.stringValue ?? ""
    if !message.isEmpty {
      return info.isEmpty ? "\(base) \(message)" : "\(base) \(message) (\(info))"
    }
    return info.isEmpty ? base : "\(base) (\(info))"
  }

  static func finalMessage(_ turn: CodexTurn) -> String {
    for item in turn.items.reversed() {
      guard let object = item.objectValue,
        object["type"]?.stringValue == "agentMessage",
        let text = object["text"]?.stringValue
      else { continue }
      let result = OutboundContentSecurity.redacted(text, maximumUTF8Bytes: 32 * 1_024)
      if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return result
      }
    }
    return "Codex completed the task."
  }

  static func isInProgress(_ evidence: CodexApprovalItemEvidence) -> Bool {
    switch evidence {
    case .commandExecution(let value): value.status == .inProgress
    case .fileChange(let value): value.status == .inProgress
    }
  }
}
