import Foundation

/// Resolves an executable without invoking a shell. Windows uses PATH and
/// PATHEXT semantics; POSIX callers can opt into inherited PATH explicitly.
public struct AgentExecutableResolver: Sendable {
  private let environment: [String: String]
  private let additionalDirectories: [String]
  private let includeEnvironmentPath: Bool
  private let includeUserDirectories: Bool
  private let preferredExtensions: [String]

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    additionalDirectories: [String] = [],
    includeEnvironmentPath: Bool = true,
    includeUserDirectories: Bool = true,
    preferredExtensions: [String] = []
  ) {
    self.environment = environment
    self.additionalDirectories = additionalDirectories
    self.includeEnvironmentPath = includeEnvironmentPath
    self.includeUserDirectories = includeUserDirectories
    self.preferredExtensions = preferredExtensions
  }

  public func resolve(_ name: String) -> String? {
    guard validName(name) else { return nil }
    let style = AgentPathStyle.current
    if AgentPathSemantics.isAbsolute(name, style: style) {
      return existingPath(name, style: style)
    }
    guard !containsPathSeparator(name, style: style) else { return nil }
    let names = candidateNames(name, style: style)
    for directory in searchDirectories() {
      for candidateName in names {
        let candidate = joined(directory, candidateName, style: style)
        guard let resolved = existingPath(candidate, style: style) else { continue }
        return resolved
      }
    }
    return nil
  }

  /// Search directories in precedence order, normalized and deduplicated.
  public func searchDirectories() -> [String] {
    let style = AgentPathStyle.current
    var values = additionalDirectories
    #if os(Windows)
      if includeEnvironmentPath, let path = environmentValue("PATH"), !path.isEmpty {
        values.append(contentsOf: splitWindowsList(path))
      }
      values.append(contentsOf: windowsTrustedDirectories())
    #else
      if includeEnvironmentPath, let path = environmentValue("PATH"), !path.isEmpty {
        values.append(contentsOf: AgentPathSemantics.splitPathList(path, style: style))
      }
      values.append(contentsOf: posixTrustedDirectories())
    #endif
    var seen = Set<String>()
    return values.compactMap { value in
      guard let normalized = normalizedDirectory(value, style: style) else { return nil }
      let key = style == .windows ? normalized.lowercased() : normalized
      guard seen.insert(key).inserted else { return nil }
      return normalized
    }
  }

  private func candidateNames(_ name: String, style: AgentPathStyle) -> [String] {
    #if os(Windows)
      guard URL(fileURLWithPath: name).pathExtension.isEmpty else { return [name] }
      let extensions = normalizedExtensions()
      return extensions.map { name + $0 }
    #else
      _ = style
      return [name]
    #endif
  }

  #if os(Windows)
    private func normalizedExtensions() -> [String] {
      let inherited =
        environmentValue("PATHEXT")
        .map { splitWindowsList($0) }
        ?? [".COM", ".EXE", ".BAT", ".CMD"]
      let values = preferredExtensions + inherited
      var seen = Set<String>()
      return values.compactMap { value in
        var candidateExtension = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateExtension.isEmpty else { return nil }
        if !candidateExtension.hasPrefix(".") { candidateExtension = "." + candidateExtension }
        let key = candidateExtension.lowercased()
        guard key == ".com" || key == ".exe" else { return nil }
        guard seen.insert(key).inserted else { return nil }
        return candidateExtension
      }
    }

    private func windowsTrustedDirectories() -> [String] {
      let systemRoot =
        environmentValue("SystemRoot") ?? environmentValue("WINDIR")
        ?? #"C:\Windows"#
      let profile = environmentValue("USERPROFILE")
      let localAppData = environmentValue("LOCALAPPDATA")
      let programRoots = [
        environmentValue("ProgramW6432"),
        environmentValue("ProgramFiles"),
        environmentValue("ProgramFiles(x86)"),
      ].compactMap { $0 }
      var directories = [
        joined(systemRoot, "System32", style: .windows),
        systemRoot,
      ]
      if includeUserDirectories, let profile {
        directories += [
          joined(profile, ".local", "bin", style: .windows),
          joined(profile, "scoop", "shims", style: .windows),
        ]
      }
      for root in programRoots {
        directories += [
          joined(root, "Git", "cmd", style: .windows),
          joined(root, "Git", "bin", style: .windows),
          joined(root, "Git", "usr", "bin", style: .windows),
          joined(root, "nodejs", style: .windows),
          joined(root, "PowerShell", "7", style: .windows),
        ]
      }
      if includeUserDirectories, let localAppData {
        directories += [
          joined(localAppData, "Programs", "Git", "cmd", style: .windows),
          joined(localAppData, "Programs", "Git", "bin", style: .windows),
          joined(localAppData, "Programs", "nodejs", style: .windows),
        ]
      }
      return directories
    }

    private func splitWindowsList(_ value: String) -> [String] {
      var result: [String] = []
      var component = ""
      var quoted = false
      for character in value {
        if character == "\"" {
          quoted.toggle()
        } else if character == ";", !quoted {
          appendSearchComponent(&result, component)
          component.removeAll(keepingCapacity: true)
        } else {
          component.append(character)
        }
      }
      guard !quoted else { return [] }
      appendSearchComponent(&result, component)
      return result
    }

    private func appendSearchComponent(_ result: inout [String], _ value: String) {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      result.append(trimmed)
    }
  #else
    private func posixTrustedDirectories() -> [String] {
      [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
      ]
    }
  #endif

  private func existingPath(_ path: String, style: AgentPathStyle) -> String? {
    guard let normalized = AgentPathSemantics.canonicalPath(path, style: style),
      AgentPathSemantics.isAbsolute(normalized, style: style),
      !normalized.contains("\0"),
      normalized.utf8.count <= 16 * 1_024
    else { return nil }
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { return nil }
    #if os(Windows)
      let pathExtension = URL(fileURLWithPath: normalized).pathExtension.lowercased()
      guard pathExtension.isEmpty || pathExtension == "com" || pathExtension == "exe" else {
        return nil
      }
      return normalized
    #else
      return FileManager.default.isExecutableFile(atPath: normalized) ? normalized : nil
    #endif
  }

  private func normalizedDirectory(_ value: String, style: AgentPathStyle) -> String? {
    guard !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil,
      let normalized = AgentPathSemantics.canonicalPath(value, style: style),
      AgentPathSemantics.isAbsolute(normalized, style: style)
    else { return nil }
    return normalized
  }

  private func joined(_ parent: String, _ components: String..., style: AgentPathStyle) -> String {
    var value = parent
    let separator = String(style == .windows ? "\\" : "/")
    for component in components {
      if !value.hasSuffix(separator) { value.append(separator) }
      value.append(component.replacingOccurrences(of: "/", with: separator))
    }
    return value
  }

  private func environmentValue(_ name: String) -> String? {
    if let value = environment[name], !value.isEmpty {
      return value
    }
    #if !os(Windows)
      return nil
    #else
      guard
        let key = environment.keys.first(where: {
          $0.caseInsensitiveCompare(name) == .orderedSame
        })
      else { return nil }
      let value = environment[key] ?? ""
      return value.isEmpty ? nil : value
    #endif
  }

  private func validName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("\0") && name.utf8.count <= 4_096
  }

  private func containsPathSeparator(_ name: String, style: AgentPathStyle) -> Bool {
    name.contains("/") || (style == .windows && name.contains("\\"))
  }
}
