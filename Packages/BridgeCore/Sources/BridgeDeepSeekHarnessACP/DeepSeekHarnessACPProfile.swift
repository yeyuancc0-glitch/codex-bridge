import BridgeAgentCore
import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DeepSeekHarnessACPProfile: Sendable {
  public let configurationTemplate: Data

  public init(configurationTemplate: Data? = nil) throws {
    if let configurationTemplate {
      guard !configurationTemplate.isEmpty,
        configurationTemplate.count <= DeepSeekHarnessACPConstants.maximumFinalTextBytes
      else {
        throw DeepSeekHarnessACPError.templateMismatch
      }
      self.configurationTemplate = configurationTemplate
    } else {
      self.configurationTemplate = try Self.bundledConfigurationTemplate()
    }
  }

  public static func bundledConfigurationTemplate() throws -> Data {
    guard let url = Bundle.module.url(forResource: "cordis", withExtension: "yml"),
      let data = try? Data(contentsOf: url),
      !data.isEmpty
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    return data
  }

  public var configurationTemplateDigest: String {
    SHA256.hash(data: configurationTemplate).map { String(format: "%02x", $0) }.joined()
  }

  public static func resolveArtifacts(
    executablePath: String,
    configurationPath: String,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [AgentInstallationArtifactRole: String] {
    let profile = try Self.init()
    let executable = try canonicalPath(executablePath, field: "launch.executable")
    let configuration = try canonicalPath(configurationPath, field: "launch.configuration")
    guard
      try boundedData(
        at: configuration,
        maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
        field: "launch_configuration.size"
      ) == profile.configurationTemplate
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }
    let sourceRoot = try findSourceRoot(startingAt: executable)
    let configurationRoot = URL(fileURLWithPath: configuration)
      .deletingLastPathComponent()
      .standardizedFileURL
      .path
    guard configurationRoot != sourceRoot,
      !configurationRoot.hasPrefix(sourceRoot + "/")
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("configuration.external_profile")
    }
    let node = try findNodeInterpreter(
      executablePath: executable,
      sourceEnvironment: sourceEnvironment
    )
    let artifacts = try [
      AgentInstallationArtifact(
        role: .launchConfiguration,
        snapshot: FileSnapshot(capturing: configuration, requiresExecutable: false)
      ),
      AgentInstallationArtifact(
        role: .runtimeManifest,
        snapshot: FileSnapshot(
          capturing: URL(fileURLWithPath: sourceRoot).appendingPathComponent("package.json").path,
          requiresExecutable: false
        )
      ),
      AgentInstallationArtifact(
        role: .dependencyLock,
        snapshot: FileSnapshot(
          capturing: URL(fileURLWithPath: sourceRoot)
            .appendingPathComponent("pnpm-lock.yaml").path,
          requiresExecutable: false
        )
      ),
      AgentInstallationArtifact(
        role: .nodeInterpreter,
        snapshot: FileSnapshot(capturing: node, requiresExecutable: true)
      ),
    ]
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "deepseek-registration-probe"),
      providerID: .deepSeekHarness,
      executablePath: executable,
      artifacts: artifacts
    )
    _ = try profile.validate(installation)
    return Dictionary(uniqueKeysWithValues: [
      (.launchConfiguration, configuration),
      (
        .runtimeManifest,
        URL(fileURLWithPath: sourceRoot).appendingPathComponent("package.json").path
      ),
      (
        .dependencyLock,
        URL(fileURLWithPath: sourceRoot).appendingPathComponent("pnpm-lock.yaml").path
      ),
      (.nodeInterpreter, node),
    ])
  }

  public func validate(_ installation: AgentInstallation) throws
    -> DeepSeekHarnessACPValidatedInstallation
  {
    guard installation.providerID == .deepSeekHarness else {
      throw AgentRuntimeError.providerUnavailable(installation.providerID)
    }
    let artifacts = try Self.requiredArtifacts(from: installation)
    let configuration = try Self.validateArtifact(
      artifacts[.launchConfiguration]!,
      role: .launchConfiguration
    )
    guard configuration.fileSize <= DeepSeekHarnessACPConstants.maximumFinalTextBytes,
      try Self.boundedData(
        at: configuration.path,
        maximumBytes: DeepSeekHarnessACPConstants.maximumFinalTextBytes,
        field: "launch_configuration.size"
      ) == configurationTemplate
    else {
      throw DeepSeekHarnessACPError.templateMismatch
    }

    let manifest = try Self.validateArtifact(
      artifacts[.runtimeManifest]!,
      role: .runtimeManifest
    )
    let lock = try Self.validateArtifact(artifacts[.dependencyLock]!, role: .dependencyLock)
    let node = try Self.validateArtifact(artifacts[.nodeInterpreter]!, role: .nodeInterpreter)
    let sourceRoot = try Self.commonSourceRoot(manifest.path, lock.path)
    let configurationRoot = URL(fileURLWithPath: configuration.path)
      .deletingLastPathComponent()
      .standardizedFileURL
      .path
    guard configurationRoot != sourceRoot,
      !configurationRoot.hasPrefix(sourceRoot + "/")
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("configuration.external_profile")
    }
    let executable = try Self.validateExecutable(
      installation.executablePath,
      sourceRoot: sourceRoot
    )
    let package = try Self.parseManifest(at: manifest.path)
    guard package.version == DeepSeekHarnessACPConstants.rootManifestVersion else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_manifest.version")
    }
    guard package.nodeRequirement == DeepSeekHarnessACPConstants.nodeRequirement else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_manifest.engines.node")
    }
    guard package.packageManager == "pnpm@\(DeepSeekHarnessACPConstants.pnpmVersion)" else {
      throw DeepSeekHarnessACPError.artifactInvalid("runtime_manifest.packageManager")
    }
    try Self.validateDependencyLock(at: lock.path)
    let nodeVersion = try Self.nodeVersion(at: node.path)
    guard Self.isCompatibleNodeVersion(nodeVersion) else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible(nodeVersion)
    }

    return DeepSeekHarnessACPValidatedInstallation(
      installation: installation,
      nodeInterpreterPath: node.path,
      executablePath: executable,
      configurationPath: configuration.path,
      sourceRoot: sourceRoot,
      nodeVersion: nodeVersion
    )
  }

  public static func isCompatibleNodeVersion(_ version: String) -> Bool {
    guard let parsed = SemanticVersion(version) else { return false }
    if parsed.major == 22 {
      return parsed >= SemanticVersion(major: 22, minor: 19, patch: 0)
    }
    return parsed.major >= 24
  }

  private static func requiredArtifacts(
    from installation: AgentInstallation
  ) throws -> [AgentInstallationArtifactRole: AgentInstallationArtifact] {
    let expected = Set(AgentInstallationArtifactRole.allCases)
    let actual = Set(installation.artifacts.map(\.role))
    guard expected.isSubset(of: actual), actual.count == installation.artifacts.count else {
      throw DeepSeekHarnessACPError.artifactInvalid("required_roles")
    }
    return Dictionary(uniqueKeysWithValues: installation.artifacts.map { ($0.role, $0) })
  }

  private static func validateArtifact(
    _ artifact: AgentInstallationArtifact,
    role: AgentInstallationArtifactRole
  ) throws -> FileSnapshot {
    guard artifact.role == role,
      artifact.canonicalPath.hasPrefix("/"),
      !artifact.canonicalPath.contains("\0"),
      artifact.canonicalPath.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.artifactInvalid(role.rawValue)
    }
    let path = URL(fileURLWithPath: artifact.canonicalPath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    guard path == artifact.canonicalPath else {
      throw DeepSeekHarnessACPError.artifactInvalid("\(role.rawValue).canonical_path")
    }
    let snapshot = try FileSnapshot(capturing: path, requiresExecutable: role.requiresExecutable)
    guard snapshot.device == artifact.device,
      snapshot.inode == artifact.inode,
      snapshot.fileSize == artifact.fileSize,
      snapshot.modificationTimeNanoseconds == artifact.modificationTimeNanoseconds,
      snapshot.sha256 == artifact.sha256
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("\(role.rawValue).identity")
    }
    return snapshot
  }

  private static func validateExecutable(_ path: String, sourceRoot: String) throws -> String {
    let canonical = try canonicalPath(path, field: "launch.executable")
    guard canonical.hasPrefix("/"), !canonical.contains("\0") else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable")
    }
    guard canonical == sourceRoot || canonical.hasPrefix(sourceRoot + "/") else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable.source_root")
    }
    _ = try FileSnapshot(capturing: canonical, requiresExecutable: true)
    return canonical
  }

  private static func canonicalPath(_ path: String, field: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16 * 1_024,
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func findSourceRoot(startingAt executable: String) throws -> String {
    var candidate = URL(fileURLWithPath: executable).deletingLastPathComponent()
    var matches: [String] = []
    while candidate.path != "/" {
      let package = candidate.appendingPathComponent("package.json").path
      let lock = candidate.appendingPathComponent("pnpm-lock.yaml").path
      if FileManager.default.fileExists(atPath: package),
        FileManager.default.fileExists(atPath: lock)
      {
        matches.append(candidate.standardizedFileURL.path)
      }
      candidate = candidate.deletingLastPathComponent()
    }
    if FileManager.default.fileExists(atPath: "/package.json"),
      FileManager.default.fileExists(atPath: "/pnpm-lock.yaml")
    {
      matches.append("/")
    }
    guard matches.count == 1, let root = matches.first else {
      throw DeepSeekHarnessACPError.artifactInvalid("source_root")
    }
    guard executable == root || executable.hasPrefix(root + "/") else {
      throw DeepSeekHarnessACPError.artifactInvalid("launch.executable.source_root")
    }
    return root
  }

  private static func findNodeInterpreter(
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
    for candidate in pathCandidates where seen.insert(candidate).inserted {
      let canonical = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
        .standardizedFileURL.path
      if (try? FileSnapshot(capturing: canonical, requiresExecutable: true)) != nil {
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
      return words.dropFirst().filter { $0.hasPrefix("/") }
    }
    return first.hasPrefix("/") ? [first] : []
  }

  private static func trustedNodeCandidates(sourceEnvironment: [String: String]) -> [String] {
    var candidates = [
      "/opt/homebrew/opt/node@22/bin/node",
      "/opt/homebrew/bin/node",
      "/usr/local/opt/node@22/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
      "/bin/node",
    ]
    if let path = sourceEnvironment["PATH"] {
      for component in path.split(separator: ":") {
        let directory = String(component)
        guard directory.hasPrefix("/"), !directory.contains("\0") else { continue }
        candidates.append(URL(fileURLWithPath: directory).appendingPathComponent("node").path)
      }
    }
    return candidates
  }

  private static func commonSourceRoot(_ manifest: String, _ lock: String) throws -> String {
    let manifestRoot = URL(fileURLWithPath: manifest).deletingLastPathComponent()
      .standardizedFileURL.path
    let lockRoot = URL(fileURLWithPath: lock).deletingLastPathComponent().standardizedFileURL.path
    guard manifestRoot == lockRoot else {
      throw DeepSeekHarnessACPError.artifactInvalid("source_root")
    }
    return manifestRoot
  }

  private static func parseManifest(at path: String) throws -> PackageManifest {
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

  private static func validateDependencyLock(at path: String) throws {
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

  private static func nodeVersion(at path: String) throws -> String {
    let process = Process()
    let output = Pipe()
    let completion = DispatchSemaphore(value: 0)
    let captured = BoundedNodeVersionOutput(maximumBytes: 4 * 1_024)
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    process.environment = [
      "PATH": URL(fileURLWithPath: path).deletingLastPathComponent().path
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { handle in
      captured.append(handle.availableData)
    }
    process.terminationHandler = { _ in completion.signal() }
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      throw DeepSeekHarnessACPError.processUnavailable
    }
    let processID = process.processIdentifier
    _ = setpgid(processID, processID)
    guard completion.wait(timeout: .now() + 5) == .success else {
      terminateProcessGroup(processID, signal: SIGTERM)
      if completion.wait(timeout: .now() + 1) == .timedOut {
        terminateProcessGroup(processID, signal: SIGKILL)
        _ = completion.wait(timeout: .now() + 1)
      }
      output.fileHandleForReading.readabilityHandler = nil
      try? output.fileHandleForReading.close()
      throw DeepSeekHarnessACPError.processUnavailable
    }
    output.fileHandleForReading.readabilityHandler = nil
    guard process.terminationStatus == 0 else {
      throw DeepSeekHarnessACPError.processExited(process.terminationStatus)
    }
    captured.append(output.fileHandleForReading.readDataToEndOfFile())
    let data = captured.value
    guard !captured.didOverflow else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible("oversized")
    }
    let value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= 128, !value.contains("\0") else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible(value)
    }
    return value
  }

  private static func boundedData(at path: String, maximumBytes: Int, field: String) throws
    -> Data
  {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DeepSeekHarnessACPError.artifactInvalid(field)
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size >= 0,
      UInt64(metadata.st_size) <= UInt64(maximumBytes)
    else {
      throw DeepSeekHarnessACPError.artifactInvalid(field)
    }
    var result = Data()
    result.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw DeepSeekHarnessACPError.artifactInvalid(field)
      }
      guard result.count + count <= maximumBytes else {
        throw DeepSeekHarnessACPError.artifactInvalid(field)
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  private static func terminateProcessGroup(_ processID: Int32, signal: Int32) {
    if kill(-processID, signal) != 0 {
      _ = kill(processID, signal)
    }
  }
}

private final class BoundedNodeVersionOutput: @unchecked Sendable {
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var overflow = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func append(_ value: Data) {
    guard !value.isEmpty else { return }
    lock.withLock {
      let available = max(0, maximumBytes - data.count)
      data.append(value.prefix(available))
      overflow = overflow || value.count > available
    }
  }

  var value: Data { lock.withLock { data } }
  var didOverflow: Bool { lock.withLock { overflow } }
}

private struct PackageManifest: Sendable {
  let version: String
  let nodeRequirement: String
  let packageManager: String
}

private struct SemanticVersion: Comparable, Equatable, Sendable {
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

private struct FileSnapshot: Sendable {
  let path: String
  let device: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeNanoseconds: Int64
  let sha256: String

  init(capturing path: String, requiresExecutable: Bool) throws {
    self.path = path
    guard path.hasPrefix("/"), !path.contains("\0"),
      path.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("path")
    }
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_uid == getuid() || metadata.st_uid == 0,
      metadata.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
      metadata.st_mode & mode_t(S_ISUID | S_ISGID) == 0,
      metadata.st_size > 0,
      UInt64(metadata.st_size) <= 1_073_741_824
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("identity")
    }
    if requiresExecutable {
      let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
      guard metadata.st_mode & executableBits != 0 else {
        throw DeepSeekHarnessACPError.artifactInvalid("executable")
      }
    }
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw DeepSeekHarnessACPError.artifactInvalid("open")
    }
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0 else {
      throw DeepSeekHarnessACPError.artifactInvalid("identity")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw DeepSeekHarnessACPError.artifactInvalid("digest")
      }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      before.st_dev == after.st_dev,
      before.st_ino == after.st_ino,
      before.st_size == after.st_size,
      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("changed")
    }
    let seconds = Int64(after.st_mtimespec.tv_sec)
    let nanoseconds = Int64(after.st_mtimespec.tv_nsec)
    let (multiplied, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let (modification, addOverflow) = multiplied.addingReportingOverflow(nanoseconds)
    guard seconds >= 0, (0..<1_000_000_000).contains(nanoseconds),
      !multiplyOverflow, !addOverflow
    else {
      throw DeepSeekHarnessACPError.artifactInvalid("mtime")
    }
    self.device = UInt64(after.st_dev)
    self.inode = UInt64(after.st_ino)
    self.fileSize = UInt64(after.st_size)
    self.modificationTimeNanoseconds = modification
    self.sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

extension AgentInstallationArtifact {
  fileprivate init(role: AgentInstallationArtifactRole, snapshot: FileSnapshot) {
    self.init(
      role: role,
      canonicalPath: snapshot.path,
      device: snapshot.device,
      inode: snapshot.inode,
      fileSize: snapshot.fileSize,
      modificationTimeNanoseconds: snapshot.modificationTimeNanoseconds,
      sha256: snapshot.sha256
    )
  }
}
