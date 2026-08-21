import BridgeSecurity
import Foundation

package enum ExecutionValidation {
  static func identifier(_ value: String, field: String, maximumBytes: Int) throws {
    guard maximumBytes > 0,
      !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= maximumBytes,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      OutboundContentSecurity.isSafe(value)
    else {
      throw ExecutionServiceError.invalidRequest(field)
    }
  }

  static func text(_ value: String, field: String, maximumBytes: Int) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      isSafeText(normalized, maximumBytes: maximumBytes)
    else {
      throw ExecutionServiceError.invalidRequest(field)
    }
  }

  static func streamDelta(_ value: String, field: String, maximumBytes: Int) throws {
    guard isSafeText(value, maximumBytes: maximumBytes) else {
      throw ExecutionServiceError.invalidRequest(field)
    }
  }

  static func optionalText(
    _ value: String?,
    field: String,
    maximumBytes: Int
  ) throws {
    guard let value else { return }
    try text(value, field: field, maximumBytes: maximumBytes)
  }

  static func relativePaths(_ values: [String], field: String) throws {
    guard values.count <= 256, Set(values).count == values.count else {
      throw ExecutionServiceError.invalidRequest(field)
    }
    for value in values where !OutboundContentSecurity.isSafeOutboundRelativePath(value) {
      throw ExecutionServiceError.invalidRequest(field)
    }
  }

  static func relativePath(_ rawValue: String, root: String) throws -> String {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 16_384, !rawValue.contains("\0") else {
      throw ExecutionServiceError.protocolViolation("file path")
    }
    let value: String
    if rawValue.hasPrefix("/") {
      let standardized = URL(fileURLWithPath: rawValue).standardizedFileURL.path
      let rootPrefix = root.hasSuffix("/") ? root : root + "/"
      guard standardized.hasPrefix(rootPrefix) else {
        throw ExecutionServiceError.protocolViolation("file path escaped the project")
      }
      value = String(standardized.dropFirst(rootPrefix.count))
    } else {
      value = rawValue
    }
    guard OutboundContentSecurity.isSafeOutboundRelativePath(value) else {
      throw ExecutionServiceError.protocolViolation("unsafe relative file path")
    }
    return value
  }

  static func redacted(_ value: String?, maximumBytes: Int) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return OutboundContentSecurity.redacted(normalized, maximumUTF8Bytes: maximumBytes)
  }

  private static func isSafeText(_ value: String, maximumBytes: Int) -> Bool {
    maximumBytes > 0 && value.utf8.count <= maximumBytes && !value.contains("\0")
      && value.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 0x09, 0x0A, 0x0D:
          true
        case 0..<0x20, 0x7F:
          false
        default:
          true
        }
      }
  }
}
