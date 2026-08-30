import BridgeAgentCore
import BridgeSecurity
import Foundation

enum DeepSeekHarnessACPArtifactRuntime {
  struct PackageManifest: Sendable {
    let version: String
    let nodeRequirement: String
    let packageManager: String
  }

  struct SemanticVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
      self.major = major
      self.minor = minor
      self.patch = patch
    }

    init?(_ value: String) {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let core = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
      let parts = core.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3,
        let major = Int(parts[0]),
        let minor = Int(parts[1]),
        let patch = Int(parts[2]),
        major >= 0, minor >= 0, patch >= 0
      else { return nil }
      self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      if lhs.major != rhs.major { return lhs.major < rhs.major }
      if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
      return lhs.patch < rhs.patch
    }
  }

  static func isCompatibleNodeVersion(_ version: String) -> Bool {
    guard let parsed = SemanticVersion(version) else { return false }
    if parsed.major == 22 {
      return parsed >= SemanticVersion(major: 22, minor: 19, patch: 0)
    }
    return parsed.major >= 24
  }

  static var launchEntryRequiresNativeExecutable: Bool {
    #if os(Windows)
      false
    #else
      true
    #endif
  }

  static func canonicalPath(_ path: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0"),
      path.utf8.count <= 16 * 1_024,
      path.rangeOfCharacter(from: .controlCharacters) == nil,
      let canonical = AgentPathSemantics.canonicalPath(
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
      )
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return canonical
  }

  static func findSourceRoot(startingAt executable: String) throws -> String {
    var candidate = URL(fileURLWithPath: executable).deletingLastPathComponent()
    var matches: [String] = []
    while true {
      guard let candidatePath = AgentPathSemantics.canonicalPath(candidate.path) else {
        throw DeepSeekHarnessACPError.artifactInvalid("source_root")
      }
      let package = try DeepSeekHarnessACPPathSupport.append("package.json", to: candidatePath)
      let lock = try DeepSeekHarnessACPPathSupport.append("pnpm-lock.yaml", to: candidatePath)
      if FileManager.default.fileExists(atPath: package),
        FileManager.default.fileExists(atPath: lock)
      {
        matches.append(candidatePath)
      }
      let parent = candidate.deletingLastPathComponent()
      guard !DeepSeekHarnessACPPathSupport.samePath(parent.path, candidate.path) else { break }
      candidate = parent
    }
    guard matches.count == 1, let root = matches.first else {
      throw DeepSeekHarnessACPError.artifactInvalid("source_root")
    }
    guard AgentPathSemantics.isContained(executable, in: root) else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable.source_root")
    }
    return root
  }

  static func findNodeInterpreter(
    executablePath: String,
    sourceEnvironment: [String: String]
  ) throws -> String {
    let shebangCandidates = try shebangInterpreters(at: executablePath)
    let pathCandidates =
      shebangCandidates
      + trustedNodeCandidates(
        sourceEnvironment: sourceEnvironment
      )
    var seen = Set<String>()
    for candidate in pathCandidates {
      guard let canonical = try? canonicalPath(candidate, field: "node_interpreter") else {
        continue
      }
      let key = AgentPathStyle.current == .windows ? canonical.lowercased() : canonical
      guard seen.insert(key).inserted else { continue }
      if (try? DeepSeekHarnessACPFileSnapshot(capturing: canonical, requiresExecutable: true))
        != nil
      {
        return canonical
      }
    }
    throw DeepSeekHarnessACPError.artifactInvalid("node_interpreter")
  }

  private static func shebangInterpreters(at executablePath: String) throws -> [String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: executablePath), options: [.mappedIfSafe])
    let firstLine = data.prefix(4 * 1_024).split(separator: 0x0A, maxSplits: 1).first
    guard let firstLine,
      let line = String(bytes: firstLine, encoding: .utf8),
      line.hasPrefix("#!")
    else { return [] }
    let words = line.dropFirst(2).split { $0 == " " || $0 == "\t" }.map(String.init)
    guard let first = words.first else { return [] }
    if URL(fileURLWithPath: first).lastPathComponent == "env" {
      return words.dropFirst().filter { AgentPathSemantics.isAbsolute($0) }
    }
    return AgentPathSemantics.isAbsolute(first) ? [first] : []
  }

  private static func trustedNodeCandidates(sourceEnvironment: [String: String]) -> [String] {
    #if os(Windows)
      var candidates: [String] = []
      let executableName = "node.exe"
    #else
      var candidates = [
        "/opt/homebrew/opt/node@22/bin/node",
        "/opt/homebrew/bin/node",
        "/usr/local/opt/node@22/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
        "/bin/node",
      ]
      let executableName = "node"
    #endif
    let path = sourceEnvironment.first(where: {
      $0.key.caseInsensitiveCompare("PATH") == .orderedSame
    })?.value
    for directory in AgentPathSemantics.splitPathList(path ?? "") {
      guard AgentPathSemantics.isAbsolute(directory), !directory.contains("\0"),
        let candidate = try? DeepSeekHarnessACPPathSupport.append(
          executableName,
          to: directory
        )
      else { continue }
      candidates.append(candidate)
    }
    return candidates
  }

  static func commonSourceRoot(_ manifest: String, _ lock: String) throws -> String {
    guard let manifestRoot = AgentPathSemantics.directoryPath(of: manifest),
      let lockRoot = AgentPathSemantics.directoryPath(of: lock),
      DeepSeekHarnessACPPathSupport.samePath(manifestRoot, lockRoot)
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("source_root")
    }
    return manifestRoot
  }

  static func parseManifest(at path: String) throws -> PackageManifest {
    let data = try boundedData(
      at: path,
      maximumBytes: 2 * 1_024 * 1_024,
      field: "runtime_manifest.size"
    )
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = json["version"] as? String,
      let engines = json["engines"] as? [String: Any],
      let nodeRequirement = engines["node"] as? String,
      let packageManager = json["packageManager"] as? String
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_manifest.json")
    }
    return PackageManifest(
      version: version,
      nodeRequirement: nodeRequirement,
      packageManager: packageManager
    )
  }

  static func validateDependencyLock(at path: String) throws {
    let data = try boundedData(
      at: path,
      maximumBytes: 128 * 1_024 * 1_024,
      field: "dependency_lock.size"
    )
    guard let value = String(data: data, encoding: .utf8),
      dependencyLockContainsExactACPVersion(value)
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("dependency_lock.acp_sdk")
    }
  }

  private static func dependencyLockContainsExactACPVersion(_ value: String) -> Bool {
    let package = "@agentclientprotocol/sdk@\(DeepSeekHarnessACPConstants.acpSDKVersion)"
    return value.split(whereSeparator: \.isNewline).contains { line in
      var key = line.trimmingCharacters(in: .whitespaces)
      if key.hasPrefix("'") || key.hasPrefix("\"") { key.removeFirst() }
      if key.hasPrefix("/") { key.removeFirst() }
      guard key.hasPrefix(package) else { return false }
      let suffix = key.dropFirst(package.count)
      return suffix.hasPrefix(":")
        || suffix.hasPrefix("':")
        || suffix.hasPrefix("\":")
        || suffix.hasPrefix("(")
    }
  }

  static func boundedData(at path: String, maximumBytes: Int, field: String) throws -> Data {
    do {
      return try SecureFileArtifactReader.read(at: path, maximumBytes: maximumBytes)
    } catch {
      throw DeepSeekHarnessACPError.artifactInvalid(field)
    }
  }
}
