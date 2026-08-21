import Foundation

public struct SecureRelativePath: Codable, Hashable, Sendable {
  public let value: String
  public let components: [String]

  public init(_ input: String) throws {
    guard !input.isEmpty else {
      throw PathSecurityError.invalidRelativePath("empty path")
    }
    guard !input.contains("\0") else {
      throw PathSecurityError.invalidRelativePath("NUL byte")
    }
    guard !input.hasPrefix("/") && !input.hasPrefix("~") else {
      throw PathSecurityError.invalidRelativePath("absolute or home-relative path")
    }
    guard !input.lowercased().hasPrefix("file:") else {
      throw PathSecurityError.invalidRelativePath("file URL")
    }

    let parts = input.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw PathSecurityError.invalidRelativePath("empty, dot, or parent component")
    }

    components = parts
    value = parts.joined(separator: "/")
  }
}
