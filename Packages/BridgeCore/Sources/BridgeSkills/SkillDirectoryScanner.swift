import Foundation

struct SkillDirectoryScanner {
  private let globalRoots: [URL]
  private let fileManager: FileManager

  init(globalRoots: [URL], fileManager: FileManager) {
    self.globalRoots = globalRoots
    self.fileManager = fileManager
  }

  func scan(projectRoot: URL?) throws -> [SkillManifest] {
    var result: [SkillManifest] = []
    var names = Set<String>()
    if let projectRoot {
      let root = projectRoot.standardizedFileURL
      for directory in ["skills", ".agents/skills", ".codex/skills"] {
        try append(
          scanDirectory(root.appendingPathComponent(directory), scope: .project),
          to: &result,
          names: &names
        )
      }
    }
    for root in globalRoots {
      try append(scanDirectory(root, scope: .global), to: &result, names: &names)
    }
    return result.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func scanDirectory(_ directory: URL, scope: SkillScope) throws -> [SkillManifest] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    )
    var manifests: [SkillManifest] = []
    for entry in entries {
      let values = try entry.resourceValues(forKeys: Set(keys))
      guard values.isDirectory == true else { continue }
      let name = entry.lastPathComponent
      guard SkillManifestMetadata.isValidSkillName(name), values.isSymbolicLink != true else {
        continue
      }
      let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
      guard
        resolved.path == resolvedDirectory.path
          || resolved.path.hasPrefix(resolvedDirectory.path + "/")
      else {
        continue
      }
      let document = entry.appendingPathComponent("SKILL.md")
      guard fileManager.isReadableFile(atPath: document.path) else { continue }
      guard let data = try? Data(contentsOf: document),
        data.count <= SkillScanner.maximumDocumentBytes,
        let text = String(data: data, encoding: .utf8),
        let metadata = try? SkillFrontmatter.parse(text)
      else { continue }

      let declaredName = SkillManifestMetadata.declaredName(from: metadata, fallback: name)
      let description = SkillManifestMetadata.description(from: metadata)
      var actions = try SkillActionCatalog.actions(
        for: entry,
        metadata: metadata,
        documentText: text,
        fileManager: fileManager
      )
      if actions.isEmpty {
        actions = SkillActionCatalog.builtInActions(for: declaredName)
      }
      let references = fileManager.fileExists(
        atPath: entry.appendingPathComponent("references").path
      )
      manifests.append(
        SkillManifest(
          name: declaredName,
          description: description,
          scope: scope,
          rootPath: resolved.path,
          triggers: SkillManifestMetadata.triggers(from: metadata),
          actions: actions,
          hasReferences: references
        )
      )
      if manifests.count >= SkillScanner.maximumSkills {
        throw SkillError.tooManySkills
      }
    }
    return manifests
  }

  private func append(
    _ items: [SkillManifest],
    to result: inout [SkillManifest],
    names: inout Set<String>
  ) throws {
    for item in items where !names.contains(item.name) {
      guard result.count < SkillScanner.maximumSkills else { throw SkillError.tooManySkills }
      result.append(item)
      names.insert(item.name)
    }
  }
}
