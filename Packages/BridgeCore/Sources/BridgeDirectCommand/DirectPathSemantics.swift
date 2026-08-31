import BridgeAgentCore
import BridgeSecurity
import Foundation

enum DirectPathSemantics {
  static func hasSeparator(_ value: String) -> Bool {
    #if os(Windows)
      return value.contains("/") || value.contains("\\")
    #else
      return value.contains("/")
    #endif
  }

  static func basename(_ value: String) -> String {
    #if os(Windows)
      return value.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        .last.map(String.init) ?? value
    #else
      return value.split(separator: "/").last.map(String.init) ?? value
    #endif
  }

  static func isAbsolute(_ value: String) -> Bool {
    AgentPathSemantics.isAbsolute(value, style: .current)
  }

  static func containedPath(
    _ value: String,
    projectRoot: String,
    workingDirectory: String?
  ) -> String? {
    guard !value.isEmpty, !value.hasPrefix("~"), !value.lowercased().hasPrefix("file:") else {
      return nil
    }
    guard let root = resolvedPath(projectRoot) else { return nil }
    let base: String
    if let workingDirectory, !workingDirectory.isEmpty,
      workingDirectory != ".", workingDirectory != "./"
    {
      guard let relative = relativePath(workingDirectory) else { return nil }
      guard let candidate = joined(root, relative.value), let resolved = resolvedPath(candidate),
        AgentPathSemantics.isContained(resolved, in: root, style: .current)
      else { return nil }
      base = resolved
    } else {
      base = root
    }

    let candidate: String
    if isAbsolute(value) {
      candidate = value
    } else {
      guard let relative = relativePathAllowingDot(value) else { return nil }
      if relative.isEmpty {
        candidate = base
      } else {
        guard let joined = joined(base, relative) else { return nil }
        candidate = joined
      }
    }
    guard let resolved = resolvedPath(candidate),
      AgentPathSemantics.isContained(resolved, in: root, style: .current)
    else { return nil }
    return resolved
  }

  static func relativePath(_ value: String) -> SecureRelativePath? {
    #if os(Windows)
      return try? SecureRelativePath(value.replacingOccurrences(of: "\\", with: "/"))
    #else
      return try? SecureRelativePath(value)
    #endif
  }

  private static func relativePathAllowingDot(_ value: String) -> String? {
    #if os(Windows)
      let normalized = value.replacingOccurrences(of: "\\", with: "/")
    #else
      let normalized = value
    #endif
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == ".." })
    else { return nil }
    return components.filter { $0 != "." }.joined(separator: "/")
  }

  static func resolvedPath(_ path: String) -> String? {
    #if os(Windows)
      guard let lexical = AgentPathSemantics.canonicalPath(path, style: .windows) else {
        return nil
      }
      let resolved = URL(fileURLWithPath: lexical).resolvingSymlinksInPath().path
      return AgentPathSemantics.canonicalPath(resolved, style: .windows) ?? lexical
    #else
      return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    #endif
  }

  static func isExecutableFile(at path: String) -> Bool {
    #if os(Windows)
      var isDirectory = ObjCBool(false)
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    #else
      return FileManager.default.isExecutableFile(atPath: path)
    #endif
  }

  private static func joined(_ parent: String, _ child: String) -> String? {
    guard !child.isEmpty else { return nil }
    #if os(Windows)
      let separator = "\\"
      let base = parent.hasSuffix(separator) ? parent : parent + separator
      return base + child.replacingOccurrences(of: "/", with: separator)
    #else
      return URL(fileURLWithPath: parent, isDirectory: true)
        .appendingPathComponent(child).path
    #endif
  }
}
