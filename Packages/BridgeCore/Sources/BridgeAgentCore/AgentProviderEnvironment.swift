import Foundation

public enum AgentProviderEnvironment {
  public static func homeDirectory(
    source: [String: String],
    field: String = "environment.HOME"
  ) throws -> String {
    try homeDirectory(source: source, field: field, style: .current)
  }

  static func homeDirectory(
    source: [String: String],
    field: String,
    style: AgentPathStyle
  ) throws -> String {
    let value = homeValue(source: source, style: style)
    guard AgentPathSemantics.isAbsolute(value, style: style),
      !value.contains("\0"),
      value.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    switch style {
    case .windows:
      guard let canonical = AgentPathSemantics.canonicalPath(value, style: style) else {
        throw AgentRuntimeError.invalidRequest(field)
      }
      return canonical
    case .posix:
      return URL(fileURLWithPath: value, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    }
  }

  public static func executableSearchPath(
    executablePath: String,
    sourcePath: String?
  ) -> String {
    executableSearchPath(executablePath: executablePath, sourcePath: sourcePath, style: .current)
  }

  public static func executableSearchPath(
    executablePath: String,
    source: [String: String]
  ) -> String {
    executableSearchPath(executablePath: executablePath, source: source, style: .current)
  }

  static func executableSearchPath(
    executablePath: String,
    source: [String: String],
    style: AgentPathStyle
  ) -> String {
    executableSearchPath(
      executablePath: executablePath,
      sourcePath: environmentValue("PATH", source: source),
      style: style
    )
  }

  static func executableSearchPath(
    executablePath: String,
    sourcePath: String?,
    style: AgentPathStyle
  ) -> String {
    let inherited = AgentPathSemantics.splitPathList(sourcePath ?? "", style: style)
      .filter { isUsableSearchDirectory($0, style: style) }
    let candidates: [String]
    switch style {
    case .windows:
      candidates =
        [AgentPathSemantics.directoryPath(of: executablePath, style: style)]
        .compactMap { $0 } + inherited
    case .posix:
      candidates =
        [
          URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        ] + inherited + [
          "/opt/homebrew/bin",
          "/usr/local/bin",
          "/usr/bin",
          "/bin",
          "/usr/sbin",
          "/sbin",
        ]
    }
    var seen = Set<String>()
    let unique = candidates.filter { candidate in
      let key: String
      if style == .windows {
        key = AgentPathSemantics.canonicalPath(candidate, style: style)?.lowercased() ?? candidate
      } else {
        key = candidate
      }
      return seen.insert(key).inserted
    }
    return AgentPathSemantics.joinPathList(unique, style: style)
  }

  private static func homeValue(source: [String: String], style: AgentPathStyle) -> String {
    switch style {
    case .windows:
      if let value = environmentValue("USERPROFILE", source: source), !value.isEmpty {
        return value
      }
      if let drive = environmentValue("HOMEDRIVE", source: source),
        let path = environmentValue("HOMEPATH", source: source),
        !drive.isEmpty,
        !path.isEmpty
      {
        return drive + path
      }
      return environmentValue("HOME", source: source)
        ?? FileManager.default.homeDirectoryForCurrentUser.path
    case .posix:
      return source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
  }

  private static func environmentValue(
    _ name: String,
    source: [String: String]
  ) -> String? {
    if let value = source[name] {
      return value
    }
    guard
      let key = source.keys.first(where: {
        $0.caseInsensitiveCompare(name) == .orderedSame
      })
    else {
      return nil
    }
    return source[key]
  }

  private static func isUsableSearchDirectory(
    _ value: String,
    style: AgentPathStyle
  ) -> Bool {
    AgentPathSemantics.isAbsolute(value, style: style)
      && value.utf8.count <= 16 * 1_024
      && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
}
