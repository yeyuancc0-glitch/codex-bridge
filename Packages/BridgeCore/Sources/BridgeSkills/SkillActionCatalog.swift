import BridgeAgentCore
import BridgeSecurity
import Foundation

enum SkillActionCatalog {
  static func actions(
    for root: URL,
    metadata: SkillFrontmatter.Node,
    documentText: String,
    fileManager: FileManager
  ) throws -> [SkillAction] {
    let entries = metadata.actionEntries("actions")
    if !entries.isEmpty {
      return try declaredActions(entries, root: root, fileManager: fileManager)
    }
    return try discoveredActions(root: root, documentText: documentText, fileManager: fileManager)
  }

  static func builtInActions(for skillName: String) -> [SkillAction] {
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

  private static func declaredActions(
    _ entries: [(String, SkillFrontmatter.Node)],
    root: URL,
    fileManager: FileManager
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
          guard case .scalar(let scalar) = value else { continue }
          switch key {
          case "name": name = scalar
          case "script", "path", "script_path": script = scalar
          case "interpreter", "executable", "interpreter_executable": interpreter = scalar
          case "network_requirement":
            guard let requirement = SkillActionNetworkRequirement(rawValue: scalar.lowercased())
            else {
              throw SkillError.invalidManifest
            }
            networkRequirement = requirement
          case "requires_network", "network":
            guard let requirement = legacyNetworkRequirement(scalar) else {
              throw SkillError.invalidManifest
            }
            networkRequirement = requirement
          case "description": description = scalar
          default: break
          }
        }
      }
      guard let resolvedName = name,
        isValidActionName(resolvedName),
        names.insert(resolvedName).inserted
      else { continue }
      let scriptPath: String
      if let script, script.contains("/") {
        scriptPath = script
      } else {
        scriptPath = "scripts/" + (script ?? resolvedName)
      }
      guard
        try scriptIsRunnable(
          scriptPath,
          root: root,
          scripts: scripts,
          fileManager: fileManager
        )
      else { continue }
      result.append(
        SkillAction(
          name: resolvedName,
          scriptPath: scriptPath,
          interpreter: interpreter,
          networkRequirement: networkRequirement,
          description: String(description.prefix(1_024))
        ))
      if result.count >= SkillScanner.maximumActionsPerSkill { break }
    }
    return result
  }

  private static func discoveredActions(
    root: URL,
    documentText: String,
    fileManager: FileManager
  ) throws -> [SkillAction] {
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
        let interpreter = try SkillActionInterpreter.interpreterForScript(
          url: entry,
          fileName: fileName,
          fileManager: fileManager
        )
      else { continue }
      let name = actionName(for: fileName)
      guard isValidActionName(name), names.insert(name).inserted else { continue }
      result.append(
        SkillAction(
          name: name,
          scriptPath: relative,
          interpreter: interpreter,
          networkRequirement: .unspecified,
          description: ""
        ))
      if result.count >= SkillScanner.maximumActionsPerSkill { break }
    }
    return result.sorted { $0.name < $1.name }
  }

  private static func scriptIsRunnable(
    _ relative: String,
    root: URL,
    scripts: URL,
    fileManager: FileManager
  ) throws -> Bool {
    _ = scripts
    let secure: SecureRelativePath
    do {
      #if os(Windows)
        secure = try SecureRelativePath(relative.replacingOccurrences(of: "\\", with: "/"))
      #else
        secure = try SecureRelativePath(relative)
      #endif
    } catch {
      return false
    }
    let target = root.appendingPathComponent(secure.components.joined(separator: "/"))
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    #if os(Windows)
      guard
        AgentPathSemantics.isContained(
          resolvedTarget,
          in: resolvedRoot,
          style: .windows
        ),
        fileManager.isReadableFile(atPath: target.path)
      else { return false }
    #else
      guard resolvedTarget.hasPrefix(resolvedRoot + "/"),
        fileManager.isReadableFile(atPath: target.path)
      else { return false }
    #endif
    return
      (try? SkillActionInterpreter.interpreterForScript(
        url: target,
        fileName: target.lastPathComponent,
        fileManager: fileManager
      )) != nil
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

  private static func legacyNetworkRequirement(
    _ value: String
  ) -> SkillActionNetworkRequirement? {
    let lower = value.lowercased()
    if ["true", "yes", "1", "on", "required"].contains(lower) { return .required }
    if ["false", "no", "0", "off", "denied"].contains(lower) { return .denied }
    if lower == "unspecified" { return .unspecified }
    return nil
  }
}
