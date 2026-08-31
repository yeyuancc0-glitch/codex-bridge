import BridgeAgentCore
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  static func resolvedWorkingDirectory(
    project: ServiceProjectRecord,
    relative: String?
  ) throws -> String {
    let root = project.root.canonicalPath
    guard let relative, !relative.isEmpty else { return root }
    var value = relative.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "." || value == "./" { return root }
    if value.hasPrefix("./") { value = String(value.dropFirst(2)) }
    #if os(Windows)
      if value.hasPrefix(".\\") { value = String(value.dropFirst(2)) }
    #endif
    if value.isEmpty { return root }
    guard !AgentPathSemantics.isAbsolute(value, style: .current) else {
      throw BridgeMCPQueryError.pathDenied
    }
    let secure: SecureRelativePath
    do {
      #if os(Windows)
        secure = try SecureRelativePath(value.replacingOccurrences(of: "\\", with: "/"))
      #else
        secure = try SecureRelativePath(value)
      #endif
    } catch {
      throw BridgeMCPQueryError.pathDenied
    }
    guard let candidate = joinedDirectPath(root, secure.value),
      let resolved = resolvedDirectPath(candidate),
      directPath(resolved, isContainedBy: root)
    else { throw BridgeMCPQueryError.pathDenied }
    return resolved
  }

  static func resolvedLaunchArgv(
    _ argv: [String],
    project: ServiceProjectRecord,
    allowUnresolvedBareExecutable: Bool = false
  ) throws -> [String] {
    guard let executable = argv.first, !executable.isEmpty else { return argv }
    if AgentPathSemantics.isAbsolute(executable, style: .current) {
      guard let lexical = canonicalDirectPath(executable),
        let root = canonicalDirectPath(project.root.canonicalPath)
      else { throw BridgeMCPQueryError.pathDenied }
      guard directPath(lexical, isContainedBy: root) else { return argv }
      return [try containedDirectPath(lexical, root: root)] + argv.dropFirst()
    }
    if hasDirectPathSeparator(executable) {
      let root = project.root.canonicalPath
      guard let candidate = joinedDirectPath(root, executable),
        let resolved = resolvedDirectPath(candidate),
        directPath(resolved, isContainedBy: root)
      else { throw BridgeMCPQueryError.pathDenied }
      return [resolved] + argv.dropFirst()
    }
    if let resolved = executableInTrustedPath(executable) {
      return [resolved] + argv.dropFirst()
    }
    #if os(Windows)
      if let resolved = AgentExecutableResolver().resolve(executable) {
        return [resolved] + argv.dropFirst()
      }
    #endif
    guard allowUnresolvedBareExecutable else { throw BridgeMCPQueryError.processLaunchFailed }
    return argv
  }

  static var trustedPathDirectories: [String] {
    AgentExecutableResolver(
      includeEnvironmentPath: false,
      includeUserDirectories: false,
      preferredExtensions: [".EXE"]
    ).searchDirectories()
  }

  static func executableInTrustedPath(_ name: String) -> String? {
    guard !name.isEmpty, !hasDirectPathSeparator(name), name.utf8.count <= 4_096 else {
      return nil
    }
    return AgentExecutableResolver(
      additionalDirectories: trustedPathDirectories,
      includeEnvironmentPath: false,
      includeUserDirectories: false,
      preferredExtensions: [".EXE"]
    ).resolve(name)
  }

  private static func containedDirectPath(_ candidate: String, root: String) throws -> String {
    guard let rootPath = resolvedDirectPath(root),
      let resolved = resolvedDirectPath(candidate),
      directPath(resolved, isContainedBy: rootPath)
    else { throw BridgeMCPQueryError.pathDenied }
    return resolved
  }

  private static func canonicalDirectPath(_ path: String) -> String? {
    AgentPathSemantics.canonicalPath(path, style: .current)
  }

  private static func resolvedDirectPath(_ path: String) -> String? {
    guard let lexical = canonicalDirectPath(path) else { return nil }
    #if os(Windows)
      let resolved = URL(fileURLWithPath: lexical).resolvingSymlinksInPath().path
      return canonicalDirectPath(resolved) ?? lexical
    #else
      return URL(fileURLWithPath: lexical).standardizedFileURL.resolvingSymlinksInPath().path
    #endif
  }

  private static func joinedDirectPath(_ root: String, _ relative: String) -> String? {
    guard !relative.isEmpty else { return nil }
    #if os(Windows)
      let base = root.hasSuffix("\\") ? root : root + "\\"
      return base + relative.replacingOccurrences(of: "/", with: "\\")
    #else
      return URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent(relative).path
    #endif
  }

  private static func hasDirectPathSeparator(_ path: String) -> Bool {
    #if os(Windows)
      return path.contains("/") || path.contains("\\")
    #else
      return path.contains("/")
    #endif
  }

  private static func directPath(_ candidate: String, isContainedBy root: String) -> Bool {
    AgentPathSemantics.isContained(candidate, in: root, style: .current)
  }
}
