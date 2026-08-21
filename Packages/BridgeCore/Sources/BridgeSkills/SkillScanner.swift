import BridgeSecurity
import Foundation

public actor SkillScanner {
  public static let maximumSkills = 256
  public static let maximumDocumentBytes = 64 * 1_024
  public static let maximumActionsPerSkill = 64

  private let globalRoots: [URL]
  private let fileManager: FileManager

  public init(
    globalRoots: [URL] = SkillScanner.defaultGlobalRoots(), fileManager: FileManager = .default
  ) {
    self.globalRoots = globalRoots.map { $0.standardizedFileURL }
    self.fileManager = fileManager
  }

  public static func defaultGlobalRoots() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent(".codex/skills"),
      home.appendingPathComponent(".agents/skills"),
      home.appendingPathComponent(".gemini/config/skills"),
    ]
  }

  public func scanSkills(for projectRoot: URL?) throws -> [SkillManifest] {
    var result: [SkillManifest] = []
    var names = Set<String>()
    if let projectRoot {
      let root = projectRoot.standardizedFileURL
      for directory in ["skills", ".agents/skills", ".codex/skills"] {
        try append(
          scanDirectory(root.appendingPathComponent(directory), scope: .project),
          to: &result, names: &names
        )
      }
    }
    for root in globalRoots {
      try append(scanDirectory(root, scope: .global), to: &result, names: &names)
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  public func readSkillDocument(
    _ manifest: SkillManifest,
    subpath: String = "SKILL.md",
    maximumBytes: Int = SkillScanner.maximumDocumentBytes
  ) throws -> SkillDocument {
    guard maximumBytes > 0, maximumBytes <= Self.maximumDocumentBytes else {
      throw SkillError.documentTooLarge
    }
    let root = URL(fileURLWithPath: manifest.rootPath).standardizedFileURL
    let relative: SecureRelativePath
    do {
      relative = try SecureRelativePath(subpath)
    } catch {
      throw SkillError.pathEscapeDetected
    }
    guard !relative.components.isEmpty else { throw SkillError.documentNotFound }
    let policy = SensitivePathPolicy()
    guard policy.allows(relative) else { throw SkillError.sensitivePath }
    let target = root.appendingPathComponent(relative.components.joined(separator: "/"))
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
      throw SkillError.pathEscapeDetected
    }
    guard fileManager.fileExists(atPath: target.path) else { throw SkillError.documentNotFound }
    let data = try Data(contentsOf: target, options: .mappedIfSafe)
    guard data.count <= maximumBytes else { throw SkillError.documentTooLarge }
    guard let content = String(data: data, encoding: .utf8) else {
      throw SkillError.invalidEncoding
    }
    return SkillDocument(
      name: manifest.name, subpath: relative.components.joined(separator: "/"),
      content: content, byteCount: data.count
    )
  }

  /// Resolve an action to its launch representation (interpreter + resolved
  /// absolute script path). `nil` interpreter means the script is launched
  /// directly via its own shebang.
  public func resolveAction(
    _ actionName: String, in manifest: SkillManifest
  ) throws -> SkillActionLaunch {
    guard let action = manifest.actions.first(where: { $0.name == actionName }) else {
      throw SkillError.actionNotFound
    }
    if let commandPrefix = action.commandPrefix {
      guard let executable = commandPrefix.first,
        let resolvedExecutable = Self.resolveInterpreter(executable)
      else { throw SkillError.actionNotRunnable }
      return SkillActionLaunch(
        action: action,
        argvPrefix: [resolvedExecutable] + commandPrefix.dropFirst()
      )
    }
    let scriptPath = try validatedScriptPath(action.scriptPath, in: manifest)
    if let interpreter = action.interpreter {
      guard let resolvedInterpreter = Self.resolveInterpreter(interpreter) else {
        throw SkillError.actionNotRunnable
      }
      return SkillActionLaunch(
        action: action, argvPrefix: [resolvedInterpreter, scriptPath]
      )
    }
    guard
      let shebang = try Self.shebangInterpreter(
        of: scriptPath, fileManager: fileManager
      )
    else {
      throw SkillError.actionNotRunnable
    }
    return SkillActionLaunch(
      action: action, argvPrefix: [shebang, scriptPath]
    )
  }

  /// Resolve an interpreter name to an absolute executable path, or `nil` when
  /// it is not installed.
  private static func resolveInterpreter(_ name: String) -> String? {
    if name.hasPrefix("/") {
      guard FileManager.default.isExecutableFile(atPath: name) else { return nil }
      return name
    }
    return resolveExecutable(name)
  }

  public struct SkillActionLaunch: Sendable {
    public let action: SkillAction
    /// Fixed, fully resolved executable and argument prefix. Caller arguments
    /// are appended without shell interpretation.
    public let argvPrefix: [String]
    public var interpreter: String { argvPrefix.first ?? "" }
    public var resolvedScriptPath: String { argvPrefix.count > 1 ? argvPrefix[1] : "" }
  }

  private func validatedScriptPath(_ scriptPath: String, in manifest: SkillManifest) throws
    -> String
  {
    let relative: SecureRelativePath
    do {
      relative = try SecureRelativePath(scriptPath)
    } catch {
      throw SkillError.pathEscapeDetected
    }
    let root = URL(fileURLWithPath: manifest.rootPath).standardizedFileURL
    let target = root.appendingPathComponent(relative.components.joined(separator: "/"))
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedTarget.hasPrefix(resolvedRoot + "/"),
      fileManager.isReadableFile(atPath: target.path)
    else {
      throw SkillError.pathEscapeDetected
    }
    return resolvedTarget
  }

  private func scanDirectory(_ directory: URL, scope: SkillScope) throws -> [SkillManifest] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    let entries = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
    )
    var manifests: [SkillManifest] = []
    for entry in entries {
      let values = try entry.resourceValues(forKeys: Set(keys))
      guard values.isDirectory == true else { continue }
      let name = entry.lastPathComponent
      guard Self.isValidSkillName(name), values.isSymbolicLink != true else { continue }
      let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
      guard
        resolved.path == resolvedDirectory.path
          || resolved.path.hasPrefix(resolvedDirectory.path + "/")
      else {
        continue
      }
      let document = entry.appendingPathComponent("SKILL.md")
      guard fileManager.isReadableFile(atPath: document.path) else { continue }
      guard let data = try? Data(contentsOf: document), data.count <= Self.maximumDocumentBytes,
        let text = String(data: data, encoding: .utf8),
        let metadata = try? SkillFrontmatter.parse(text)
      else { continue }
      let declaredName =
        metadata.scalar("name").flatMap { Self.isValidSkillName($0) ? $0 : nil } ?? name
      let description = Self.description(from: metadata)
      var actions = try actions(for: entry, metadata: metadata, documentText: text)
      if actions.isEmpty {
        actions = Self.builtInActions(for: declaredName)
      }
      let references = fileManager.fileExists(
        atPath: entry.appendingPathComponent("references").path)
      manifests.append(
        SkillManifest(
          name: declaredName,
          description: description,
          scope: scope,
          rootPath: resolved.path,
          triggers: Self.triggers(from: metadata),
          actions: actions,
          hasReferences: references
        ))
      if manifests.count >= Self.maximumSkills { throw SkillError.tooManySkills }
    }
    return manifests
  }

  private func actions(
    for root: URL, metadata: SkillFrontmatter.Node, documentText: String
  ) throws -> [SkillAction] {
    let entries = metadata.actionEntries("actions")
    if !entries.isEmpty {
      return try declaredActions(entries, root: root)
    }
    return try discoveredActions(root: root, documentText: documentText)
  }

  /// Build actions from explicit `actions:` metadata. Each entry is either a
  /// scalar action name (resolved against `scripts/` by name) or a mapping with
  /// `name`, `script`/`path`, `interpreter`, `requires_network`, `description`.
  private func declaredActions(
    _ entries: [(String, SkillFrontmatter.Node)], root: URL
  ) throws -> [SkillAction] {
    var result: [SkillAction] = []
    var names = Set<String>()
    let scripts = root.appendingPathComponent("scripts")
    for element in entries {
      let node = element.1
      var name: String?
      var script: String?
      var interpreter: String?
      var networkRequirement = SkillActionNetworkRequirement.unspecified
      var description = ""
      if case .scalar(let scalar) = node {
        name = scalar
        script = "scripts/" + scalar
      } else if case .mapping(let pairs) = node {
        for (key, value) in pairs {
          guard case .scalar(let s) = value else { continue }
          switch key {
          case "name": name = s
          case "script", "path", "script_path": script = s
          case "interpreter", "executable", "interpreter_executable": interpreter = s
          case "network_requirement":
            guard let requirement = SkillActionNetworkRequirement(rawValue: s.lowercased()) else {
              throw SkillError.invalidManifest
            }
            networkRequirement = requirement
          case "requires_network", "network":
            guard let requirement = Self.legacyNetworkRequirement(s) else {
              throw SkillError.invalidManifest
            }
            networkRequirement = requirement
          case "description": description = s
          default: break
          }
        }
      }
      guard let resolvedName = name, Self.isValidActionName(resolvedName),
        names.insert(resolvedName).inserted
      else { continue }
      let scriptPath: String
      if let script, script.contains("/") {
        scriptPath = script
      } else {
        scriptPath = "scripts/" + (script ?? resolvedName)
      }
      guard try scriptIsRunnable(scriptPath, root: root, scripts: scripts) else { continue }
      result.append(
        SkillAction(
          name: resolvedName,
          scriptPath: scriptPath,
          interpreter: interpreter,
          networkRequirement: networkRequirement,
          description: String(description.prefix(1_024))
        ))
      if result.count >= Self.maximumActionsPerSkill { break }
    }
    return result
  }

  /// Compatibility discovery only accepts a top-level script with an exact
  /// `scripts/<filename>` reference in SKILL.md. A shebang or extension alone
  /// cannot distinguish a public action from an internal helper or library.
  private func discoveredActions(root: URL, documentText: String) throws -> [SkillAction] {
    let scripts = root.appendingPathComponent("scripts")
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: scripts,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    var result: [SkillAction] = []
    var names = Set<String>()
    for entry in entries {
      guard let isDirectory = try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
        isDirectory != true
      else { continue }
      let fileName = entry.lastPathComponent
      guard !fileName.hasPrefix(".") else { continue }
      let relative = "scripts/" + fileName
      guard documentText.contains(relative) else { continue }
      guard
        let interpreter = try Self.interpreterForScript(
          url: entry, fileName: fileName, fileManager: fileManager
        )
      else { continue }
      let name = Self.actionName(for: fileName)
      guard Self.isValidActionName(name), names.insert(name).inserted else { continue }
      result.append(
        SkillAction(
          name: name,
          scriptPath: relative,
          interpreter: interpreter,
          networkRequirement: .unspecified,
          description: ""
        ))
      if result.count >= Self.maximumActionsPerSkill { break }
    }
    return result.sorted { $0.name < $1.name }
  }

  private func scriptIsRunnable(_ relative: String, root: URL, scripts: URL) throws -> Bool {
    let secure: SecureRelativePath
    do {
      secure = try SecureRelativePath(relative)
    } catch {
      return false
    }
    let target = root.appendingPathComponent(secure.components.joined(separator: "/"))
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedTarget.hasPrefix(resolvedRoot + "/"),
      fileManager.isReadableFile(atPath: target.path)
    else {
      return false
    }
    return
      (try? Self.interpreterForScript(
        url: target, fileName: target.lastPathComponent, fileManager: fileManager
      )) != nil
  }

  private func append(
    _ items: [SkillManifest], to result: inout [SkillManifest], names: inout Set<String>
  ) throws {
    for item in items where !names.contains(item.name) {
      guard result.count < Self.maximumSkills else { throw SkillError.tooManySkills }
      result.append(item)
      names.insert(item.name)
    }
  }

  private static func isValidSkillName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name == trimmed && !name.isEmpty && name.utf8.count <= 128
      && name.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private static func isValidActionName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 128
      && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
  }

  private static func actionName(for fileName: String) -> String {
    var name = fileName
    for ext in ["", ".sh", ".py", ".js", ".mjs", ".cjs", ".rb", ".pl", ".swift"] where !ext.isEmpty
    {
      if name.hasSuffix(ext) {
        name = String(name.dropLast(ext.count))
        break
      }
    }
    return name
  }

  /// Determine the interpreter for a script file, or `nil` when not runnable.
  private static func interpreterForScript(
    url: URL, fileName: String, fileManager: FileManager
  ) throws -> String? {
    if let shebang = try shebangInterpreter(of: url.path, fileManager: fileManager) {
      return shebang
    }
    return extensionInterpreter(for: fileName)
  }

  /// Parse a script's shebang line into an absolute interpreter path.
  private static func shebangInterpreter(of path: String, fileManager: FileManager) throws
    -> String?
  {
    guard fileManager.isReadableFile(atPath: path),
      let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 256), !data.isEmpty,
      data[0] == 0x23, data.count >= 2, data[1] == 0x21
    else { return nil }
    guard let line = String(data: data, encoding: .utf8) else { return nil }
    let newlineIndex = line.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? line.endIndex
    var parts = line[line.startIndex..<newlineIndex].split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return nil }
    parts[0] = String(parts[0].dropFirst(2))
    guard !parts[0].isEmpty else { return nil }
    var command = parts[0]
    if command == "/usr/bin/env" {
      guard parts.count >= 2 else { return nil }
      command = parts[1]
    }
    if command.hasPrefix("/") {
      guard fileManager.isExecutableFile(atPath: command) else { return nil }
      return command
    }
    return Self.resolveExecutable(command)
  }

  private static func extensionInterpreter(for fileName: String) -> String? {
    let lower = fileName.lowercased()
    if lower.hasSuffix(".sh") { return resolveExecutable("sh") }
    if lower.hasSuffix(".py") { return resolveExecutable("python3") }
    if lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs") || lower.hasSuffix(".js") {
      return resolveExecutable("node")
    }
    if lower.hasSuffix(".rb") { return resolveExecutable("ruby") }
    if lower.hasSuffix(".pl") { return resolveExecutable("perl") }
    return nil
  }

  /// Resolve a bare command name against the trusted PATH. Returns `nil` when
  /// the interpreter is not installed so the file is not exposed as an action.
  private static func resolveExecutable(_ name: String) -> String? {
    guard !name.isEmpty, !name.contains("/"), name.utf8.count <= 4_096 else { return nil }
    let directories = [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
      "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    for directory in directories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private static func builtInActions(for skillName: String) -> [SkillAction] {
    guard skillName == "agent-reach" else { return [] }
    let definitions: [(String, [String], String)] = [
      ("doctor", ["agent-reach", "doctor", "--json"], "Inspect active Agent Reach backends."),
      ("check_update", ["agent-reach", "check-update"], "Check for an Agent Reach update."),
      ("reddit_search", ["opencli", "reddit", "search"], "Search Reddit."),
      ("reddit_read", ["opencli", "reddit", "read"], "Read a Reddit post."),
      ("reddit_subreddit", ["opencli", "reddit", "subreddit"], "Read a subreddit."),
      ("twitter_search", ["opencli", "twitter", "search"], "Search Twitter/X."),
      ("xiaohongshu_search", ["opencli", "xiaohongshu", "search"], "Search Xiaohongshu."),
      ("xiaohongshu_note", ["opencli", "xiaohongshu", "note"], "Read a Xiaohongshu note."),
      ("bilibili_search", ["opencli", "bilibili", "search"], "Search Bilibili."),
      ("bilibili_video", ["opencli", "bilibili", "video"], "Read Bilibili video metadata."),
      ("bilibili_subtitle", ["opencli", "bilibili", "subtitle"], "Read Bilibili subtitles."),
      ("facebook_search", ["opencli", "facebook", "search"], "Search Facebook."),
      ("facebook_profile", ["opencli", "facebook", "profile"], "Read a Facebook profile."),
      ("instagram_search", ["opencli", "instagram", "search"], "Search Instagram."),
      ("instagram_profile", ["opencli", "instagram", "profile"], "Read an Instagram profile."),
      ("instagram_user", ["opencli", "instagram", "user"], "Read Instagram user posts."),
    ]
    return definitions.map { name, prefix, description in
      SkillAction(
        name: name,
        commandPrefix: prefix,
        networkRequirement: .required,
        description: description
      )
    }
  }

  private static func legacyNetworkRequirement(
    _ value: String
  ) -> SkillActionNetworkRequirement? {
    let lower = value.lowercased()
    if ["true", "yes", "1", "on", "required"].contains(lower) { return .required }
    if ["false", "no", "0", "off", "denied"].contains(lower) { return .denied }
    if lower == "unspecified" { return .unspecified }
    return nil
  }

  private static func description(from metadata: SkillFrontmatter.Node) -> String {
    guard let scalar = metadata.scalar("description") else { return "" }
    let cleaned = scalar.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }.joined(separator: " ")
    return String(cleaned.prefix(1_024))
  }

  private static func triggers(from metadata: SkillFrontmatter.Node) -> [String] {
    let values = metadata.stringArray("triggers")
    return Array(values.prefix(32))
  }
}
