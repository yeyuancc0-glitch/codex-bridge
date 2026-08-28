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
    try SkillDirectoryScanner(globalRoots: globalRoots, fileManager: fileManager)
      .scan(projectRoot: projectRoot)
  }

  public func readSkillDocument(
    _ manifest: SkillManifest,
    subpath: String = "SKILL.md",
    maximumBytes: Int = SkillScanner.maximumDocumentBytes
  ) throws -> SkillDocument {
    try SkillDocumentReader.read(
      manifest,
      subpath: subpath,
      maximumBytes: maximumBytes,
      fileManager: fileManager
    )
  }

  /// Resolve an action to its launch representation (interpreter + resolved
  /// absolute script path). `nil` interpreter means the script is launched
  /// directly via its own shebang.
  public func resolveAction(
    _ actionName: String,
    in manifest: SkillManifest
  ) throws -> SkillActionLaunch {
    try SkillActionResolver.resolve(actionName, in: manifest, fileManager: fileManager)
  }

  public struct SkillActionLaunch: Sendable {
    public let action: SkillAction
    /// Fixed, fully resolved executable and argument prefix. Caller arguments
    /// are appended without shell interpretation.
    public let argvPrefix: [String]
    public var interpreter: String { argvPrefix.first ?? "" }
    public var resolvedScriptPath: String { argvPrefix.count > 1 ? argvPrefix[1] : "" }
  }
}
