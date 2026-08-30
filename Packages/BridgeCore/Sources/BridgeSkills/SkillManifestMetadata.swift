import Foundation

enum SkillManifestMetadata {
  static func declaredName(from metadata: SkillFrontmatter.Node, fallback: String) -> String {
    metadata.scalar("name").flatMap { isValidSkillName($0) ? $0 : nil } ?? fallback
  }

  static func isValidSkillName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name == trimmed && !name.isEmpty && name.utf8.count <= 128
      && name.rangeOfCharacter(from: .controlCharacters) == nil
  }

  static func description(from metadata: SkillFrontmatter.Node) -> String {
    guard let scalar = metadata.scalar("description") else { return "" }
    let cleaned = scalar.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }.joined(separator: " ")
    return String(cleaned.prefix(1_024))
  }

  static func triggers(from metadata: SkillFrontmatter.Node) -> [String] {
    Array(metadata.stringArray("triggers").prefix(32))
  }
}
