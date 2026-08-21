import Foundation

public struct SensitivePathPolicy: Sendable {
  private let forbiddenBasenames: Set<String>
  private let forbiddenComponents: Set<String>
  private let forbiddenSuffixes: [String]

  public init(
    forbiddenBasenames: Set<String> = [
      ".env", "auth.json", "cookies", "login data",
    ],
    forbiddenComponents: Set<String> = [
      ".ssh", "secrets", "keychains", "cookies",
    ],
    forbiddenSuffixes: [String] = [
      ".pem", ".key", ".p12", ".mobileprovision",
    ]
  ) {
    self.forbiddenBasenames = Set(forbiddenBasenames.map { $0.lowercased() })
    self.forbiddenComponents = Set(forbiddenComponents.map { $0.lowercased() })
    self.forbiddenSuffixes = forbiddenSuffixes.map { $0.lowercased() }
  }

  public func allows(_ path: SecureRelativePath) -> Bool {
    let components = path.components.map { $0.lowercased() }
    guard let basename = components.last else { return false }

    if basename == ".env" || basename.hasPrefix(".env.") {
      return false
    }
    if forbiddenBasenames.contains(basename) {
      return false
    }
    if components.contains(where: forbiddenComponents.contains) {
      return false
    }
    return !forbiddenSuffixes.contains(where: basename.hasSuffix)
  }
}
