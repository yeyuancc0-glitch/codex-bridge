import Foundation

public enum AgentPathSemantics {
  public static func isAbsolute(
    _ path: String,
    style: AgentPathStyle = .current
  ) -> Bool {
    guard let parsed = parse(path, style: style) else { return false }
    if case .relative = parsed.root { return false }
    return true
  }

  public static func splitPathList(
    _ value: String,
    style: AgentPathStyle = .current
  ) -> [String] {
    value.split(separator: style.listSeparator).map(String.init)
  }

  public static func joinPathList(
    _ values: [String],
    style: AgentPathStyle = .current
  ) -> String {
    values.joined(separator: String(style.listSeparator))
  }

  public static func relativeComponents(
    _ path: String,
    style: AgentPathStyle = .current
  ) -> [String]? {
    guard !path.isEmpty, !path.contains("\0"), let parsed = parse(path, style: style) else {
      return nil
    }
    guard case .relative = parsed.root else { return nil }
    let parts = splitComponents(path, style: style, omittingEmptySubsequences: false)
    guard !parts.isEmpty,
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      return nil
    }
    return parts
  }

  static func normalizedRelativePath(_ path: String, style: AgentPathStyle = .current) -> String? {
    guard let components = relativeComponents(path, style: style) else { return nil }
    let value = components.joined(separator: String(style.pathSeparator))
    return style == .windows ? value.lowercased() : value
  }

  /// Lexically normalizes syntax; it does not resolve symlinks or reparse points.
  public static func canonicalPath(
    _ path: String,
    style: AgentPathStyle = .current
  ) -> String? {
    guard let parsed = parse(path, style: style) else { return nil }
    let value = render(parsed, style: style)
    return value.isEmpty ? nil : value
  }

  public static func isContained(
    _ candidate: String,
    in root: String,
    style: AgentPathStyle = .current
  ) -> Bool {
    guard let pair = containedComponents(candidate, root: root, style: style) else { return false }
    return matchesPrefix(pair.candidate, pair.root, style: style)
  }

  public static func relativePath(
    _ candidate: String,
    from root: String,
    style: AgentPathStyle = .current
  ) -> String? {
    guard let pair = containedComponents(candidate, root: root, style: style),
      matchesPrefix(pair.candidate, pair.root, style: style)
    else {
      return nil
    }
    return pair.candidate.dropFirst(pair.root.count)
      .joined(separator: String(style.pathSeparator))
  }

  public static func directoryPath(
    of path: String,
    style: AgentPathStyle = .current
  ) -> String? {
    guard let parsed = parse(path, style: style), !parsed.components.isEmpty else {
      return nil
    }
    let parent = ParsedPath(root: parsed.root, components: Array(parsed.components.dropLast()))
    return render(parent, style: style)
  }

  private enum Root: Equatable {
    case relative
    case posix
    case drive(String)
    case unc(server: String, share: String)
  }

  private struct ParsedPath {
    let root: Root
    let components: [String]
  }

  private static func parse(_ path: String, style: AgentPathStyle) -> ParsedPath? {
    guard !path.isEmpty, !path.contains("\0") else { return nil }
    return style == .windows ? parseWindows(path) : parsePosix(path)
  }

  private static func parsePosix(_ path: String) -> ParsedPath? {
    let absolute = path.first == "/"
    let parts = splitComponents(path, style: .posix, omittingEmptySubsequences: true)
    guard let components = normalize(parts, absolute: absolute) else { return nil }
    return ParsedPath(root: absolute ? .posix : .relative, components: components)
  }
  private static func parseWindows(_ path: String) -> ParsedPath? {
    guard !hasWindowsNamespacePrefix(path) else { return nil }
    let characters = Array(path)
    guard !characters.isEmpty else { return nil }

    let drive: (index: Int, componentsStart: Int)?
    if characters.count >= 4,
      isSeparator(characters[0], style: .windows),
      characters[1].isASCII && characters[1].isLetter,
      characters[2] == ":",
      isSeparator(characters[3], style: .windows)
    {
      drive = (1, 4)
    } else if characters.count >= 3,
      characters[0].isASCII && characters[0].isLetter,
      characters[1] == ":",
      isSeparator(characters[2], style: .windows)
    {
      drive = (0, 3)
    } else {
      drive = nil
    }
    if let drive {
      let remainder = String(characters[drive.componentsStart..<characters.count])
      guard !remainder.contains(":") else { return nil }
      let parts = splitComponents(
        remainder,
        style: .windows,
        omittingEmptySubsequences: true
      )
      guard let components = normalize(parts, absolute: true) else { return nil }
      return ParsedPath(
        root: .drive(String(characters[drive.index])),
        components: components
      )
    }

    if isSeparator(characters[0], style: .windows) {
      guard characters.count >= 2, isSeparator(characters[1], style: .windows) else { return nil }
      guard !path.contains(":") else { return nil }
      let parts = splitComponents(
        String(characters[2..<characters.count]),
        style: .windows,
        omittingEmptySubsequences: true
      )
      guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
        parts[0] != ".", parts[0] != "..", parts[1] != ".", parts[1] != ".."
      else {
        return nil
      }
      guard let components = normalize(Array(parts.dropFirst(2)), absolute: true) else {
        return nil
      }
      return ParsedPath(
        root: .unc(server: parts[0], share: parts[1]),
        components: components
      )
    }

    guard !characters.contains(":") else { return nil }
    let parts = splitComponents(path, style: .windows, omittingEmptySubsequences: true)
    guard let components = normalize(parts, absolute: false) else { return nil }
    return ParsedPath(root: .relative, components: components)
  }

  private static func normalize(_ parts: [String], absolute: Bool) -> [String]? {
    var result: [String] = []
    for part in parts {
      if part.isEmpty || part == "." { continue }
      if part == ".." {
        if result.isEmpty {
          if absolute { continue }
          return nil
        }
        result.removeLast()
        continue
      }
      result.append(part)
    }
    return result
  }

  private static func splitComponents(
    _ path: String,
    style: AgentPathStyle,
    omittingEmptySubsequences: Bool
  ) -> [String] {
    var result: [String] = []
    var component = ""
    for character in path {
      let isSeparator = isSeparator(character, style: style)
      if isSeparator {
        if !component.isEmpty || !omittingEmptySubsequences {
          result.append(component)
        }
        component.removeAll(keepingCapacity: true)
      } else {
        component.append(character)
      }
    }
    if !component.isEmpty || !omittingEmptySubsequences {
      result.append(component)
    }
    return result
  }

  private static func render(_ path: ParsedPath, style: AgentPathStyle) -> String {
    let separator = String(style.pathSeparator)
    let components = path.components.joined(separator: separator)
    switch path.root {
    case .relative:
      return components
    case .posix:
      return components.isEmpty ? "/" : "/" + components
    case .drive(let drive):
      return components.isEmpty ? "\(drive):\\" : "\(drive):\\" + components
    case .unc(let server, let share):
      let prefix = "\\\\\(server)\\\(share)"
      return components.isEmpty ? prefix : prefix + "\\" + components
    }
  }

  private static func containedComponents(
    _ candidate: String,
    root: String,
    style: AgentPathStyle
  ) -> (candidate: [String], root: [String])? {
    guard let candidatePath = parse(candidate, style: style),
      let rootPath = parse(root, style: style),
      candidatePath.root != .relative,
      rootPath.root != .relative,
      equalRoot(candidatePath.root, rootPath.root, style: style)
    else {
      return nil
    }
    return (candidatePath.components, rootPath.components)
  }

  private static func matchesPrefix(
    _ candidate: [String],
    _ root: [String],
    style: AgentPathStyle
  ) -> Bool {
    guard candidate.count >= root.count else { return false }
    return zip(root, candidate).allSatisfy {
      equalComponent($0.0, $0.1, style: style)
    }
  }

  private static func equalRoot(_ lhs: Root, _ rhs: Root, style: AgentPathStyle) -> Bool {
    switch (lhs, rhs) {
    case (.posix, .posix):
      return true
    case (.drive(let left), .drive(let right)):
      return equalComponent(left, right, style: style)
    case (.unc(let leftServer, let leftShare), .unc(let rightServer, let rightShare)):
      return equalComponent(leftServer, rightServer, style: style)
        && equalComponent(leftShare, rightShare, style: style)
    default:
      return false
    }
  }

  private static func equalComponent(
    _ lhs: String,
    _ rhs: String,
    style: AgentPathStyle
  ) -> Bool {
    style == .windows ? lhs.caseInsensitiveCompare(rhs) == .orderedSame : lhs == rhs
  }

  private static func hasWindowsNamespacePrefix(_ path: String) -> Bool {
    let value = path.replacingOccurrences(of: "/", with: "\\").lowercased()
    return value.hasPrefix("\\\\?\\")
      || value.hasPrefix("\\\\.\\")
      || value.hasPrefix("\\??\\")
      || value.hasPrefix("\\device\\")
      || value.hasPrefix("\\\\device\\")
  }

  private static func isSeparator(_ character: Character, style: AgentPathStyle) -> Bool {
    character == "/" || (style == .windows && character == "\\")
  }
}
