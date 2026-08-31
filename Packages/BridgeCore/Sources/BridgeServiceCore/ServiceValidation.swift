import BridgeAgentCore
import BridgeProjects
import Foundation

enum ServiceValidation {
  static func identifier(_ value: String, field: String, maximumBytes: Int) throws {
    guard !value.isEmpty,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count <= maximumBytes,
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw ServiceStoreError.invalidArgument(field)
    }
  }

  static func text(
    _ value: String,
    field: String,
    maximumBytes: Int,
    allowEmpty: Bool = false
  ) throws {
    guard value.utf8.count <= maximumBytes,
      !value.contains("\0"),
      !value.unicodeScalars.contains(where: isUnsafeTextScalar),
      allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ServiceStoreError.invalidArgument(field)
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

  static func date(_ value: Date, field: String) throws {
    guard value.timeIntervalSince1970.isFinite else {
      throw ServiceStoreError.invalidArgument(field)
    }
  }

  static func absolutePath(_ value: String, field: String) throws {
    guard AgentPathSemantics.isAbsolute(value),
      value.utf8.count <= 16 * 1_024,
      !value.contains("\0")
    else {
      throw ServiceStoreError.invalidArgument(field)
    }
  }

  static func projectPolicy(_ policy: ProjectAccessPolicy) throws {
    let allowed: Set<ProjectPermission> = [.denied, .requiresLocalApproval, .allowed]
    guard allowed.contains(policy.read),
      allowed.contains(policy.write),
      allowed.contains(policy.network)
    else {
      throw ServiceStoreError.invalidArgument("project.accessPolicy")
    }
  }

  static func relativePath(_ value: String, field: String) throws {
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard !value.isEmpty,
      value.utf8.count <= 1_024,
      !value.hasPrefix("/"),
      !value.hasPrefix("~"),
      !value.contains("\\"),
      !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw ServiceStoreError.invalidArgument(field)
    }
  }

  static func uniqueRelativePaths(_ values: [String], field: String) throws {
    guard values.count <= 200, Set(values).count == values.count else {
      throw ServiceStoreError.invalidArgument(field)
    }
    for value in values {
      try relativePath(value, field: field)
    }
  }

  private static func isUnsafeTextScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0D:
      false
    case 0..<0x20, 0x7F:
      true
    default:
      false
    }
  }
}
