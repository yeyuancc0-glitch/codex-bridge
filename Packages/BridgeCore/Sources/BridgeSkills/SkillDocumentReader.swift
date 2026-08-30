import BridgeSecurity
import Foundation

enum SkillDocumentReader {
  static func read(
    _ manifest: SkillManifest,
    subpath: String,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> SkillDocument {
    guard maximumBytes > 0, maximumBytes <= SkillScanner.maximumDocumentBytes else {
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
      name: manifest.name,
      subpath: relative.components.joined(separator: "/"),
      content: content,
      byteCount: data.count
    )
  }
}
