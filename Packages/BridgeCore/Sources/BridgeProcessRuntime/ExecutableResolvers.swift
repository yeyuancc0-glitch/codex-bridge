import BridgePlatform
import Foundation

public struct ExecutableResolverSelection: Sendable {
  public static func firstValid(
    _ candidates: [URL],
    validate: (URL) -> Bool
  ) -> URL? {
    var seen = Set<String>()
    for candidate in candidates {
      let key = candidate.path.lowercased()
      guard seen.insert(key).inserted else { continue }
      if validate(candidate) { return candidate }
    }
    return nil
  }
}

public struct CodexExecutableResolver: Sendable {
  public typealias Validator = @Sendable (URL, PlatformArchitecture) -> Bool

  private let environment: [String: String]
  private let processArchitecture: PlatformArchitecture
  private let validator: Validator

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processArchitecture: PlatformArchitecture = TargetPlatformArchitecture.current,
    validator: @escaping Validator = CodexExecutableResolver.defaultValidator
  ) {
    self.environment = environment
    self.processArchitecture = processArchitecture
    self.validator = validator
  }

  public func resolve(explicitURL: URL? = nil) -> URL? {
    #if canImport(WinSDK)
      let paths = Self.windowsResolutionCandidatePaths(
        explicitPath: explicitURL?.path,
        environment: environment,
        processArchitecture: processArchitecture
      )
      return ExecutableResolverSelection.firstValid(
        paths.map { URL(fileURLWithPath: $0) },
        validate: { validator($0, processArchitecture) }
      )
    #else
      if let explicitURL { return explicitURL }
      return ExecutableResolverSelection.firstValid(Self.macOSCandidateURLs()) {
        validator($0, processArchitecture)
      }
    #endif
  }

  static func windowsResolutionCandidatePaths(
    explicitPath: String?,
    environment: [String: String],
    processArchitecture: PlatformArchitecture
  ) -> [String] {
    if let explicitPath {
      return expandedExplicitWindowsPaths(
        explicitPath,
        processArchitecture: processArchitecture
      )
    }
    return windowsCandidatePaths(
      environment: environment,
      processArchitecture: processArchitecture
    )
  }

  public static func windowsCandidatePaths(
    environment: [String: String],
    processArchitecture: PlatformArchitecture
  ) -> [String] {
    let appData = WindowsPath.environmentValue("APPDATA", in: environment)
    let localAppData = WindowsPath.environmentValue("LOCALAPPDATA", in: environment)
    let programFiles = WindowsPath.environmentValue("ProgramFiles", in: environment)
    let programFilesX86 = WindowsPath.environmentValue("ProgramFiles(x86)", in: environment)
    let programW6432 = WindowsPath.environmentValue("ProgramW6432", in: environment)
    let userProfile = WindowsPath.environmentValue("USERPROFILE", in: environment)

    var result: [String] = []
    appendConfiguredExecutable(
      environment: environment,
      processArchitecture: processArchitecture,
      to: &result
    )
    appendOfficialInstallations(
      localAppData: localAppData,
      programFiles: programFiles,
      programFilesX86: programFilesX86,
      programW6432: programW6432,
      userProfile: userProfile,
      to: &result
    )

    for root in packageRoots(
      appData: appData,
      localAppData: localAppData,
      userProfile: userProfile
    ) {
      result.append(
        contentsOf: nativeCodexPaths(
          packageRoot: root,
          processArchitecture: processArchitecture
        ))
    }

    let trustedDirectories = trustedPathDirectories(
      appData: appData,
      localAppData: localAppData,
      programFiles: programFiles,
      programFilesX86: programFilesX86,
      programW6432: programW6432,
      userProfile: userProfile
    )
    let path = WindowsPath.environmentValue("PATH", in: environment) ?? ""
    for directory in WindowsPath.splitSearchPath(path) {
      guard WindowsPath.isContained(directory, inAny: trustedDirectories) else { continue }
      result.append(WindowsPath.join(directory, "codex.exe"))
      result.append(
        contentsOf: nativeCodexPaths(
          packageRoot: WindowsPath.join(directory, "node_modules", "@openai", "codex"),
          processArchitecture: processArchitecture
        ))
      result.append(
        contentsOf: nativeCodexPaths(
          packageRoot: WindowsPath.join(
            WindowsPath.parent(directory),
            "node_modules",
            "@openai",
            "codex"
          ),
          processArchitecture: processArchitecture
        ))
    }
    return WindowsPath.unique(result)
  }

  public static func expandedExplicitWindowsPaths(
    _ path: String,
    processArchitecture: PlatformArchitecture
  ) -> [String] {
    let normalized = WindowsPath.normalize(path)
    let lower = normalized.lowercased()
    if lower.hasSuffix(".bat") { return [] }
    guard lower.hasSuffix(".cmd") else { return [normalized] }
    guard WindowsPath.basename(normalized).lowercased() == "codex.cmd" else { return [] }

    let prefix = WindowsPath.parent(normalized)
    let packageRoot = WindowsPath.join(prefix, "node_modules", "@openai", "codex")
    return nativeCodexPaths(
      packageRoot: packageRoot,
      processArchitecture: processArchitecture
    )
  }

  public static func nativeCodexPaths(
    packageRoot: String,
    processArchitecture: PlatformArchitecture
  ) -> [String] {
    architectures(for: processArchitecture).flatMap { architecture in
      let packageName: String
      let triple: String
      switch architecture {
      case .arm64:
        packageName = "codex-win32-arm64"
        triple = "aarch64-pc-windows-msvc"
      case .amd64:
        packageName = "codex-win32-x64"
        triple = "x86_64-pc-windows-msvc"
      case .unknown:
        return [] as [String]
      }
      return [
        WindowsPath.join(
          packageRoot,
          "node_modules",
          "@openai",
          packageName,
          "vendor",
          triple,
          "bin",
          "codex.exe"
        ),
        WindowsPath.join(
          WindowsPath.parent(packageRoot),
          packageName,
          "vendor",
          triple,
          "bin",
          "codex.exe"
        ),
        WindowsPath.join(packageRoot, "vendor", triple, "bin", "codex.exe"),
      ]
    }
  }

  private static func appendConfiguredExecutable(
    environment: [String: String],
    processArchitecture: PlatformArchitecture,
    to result: inout [String]
  ) {
    guard
      let configured = WindowsPath.environmentValue(
        "CODEX_BRIDGE_CODEX_EXECUTABLE",
        in: environment
      ), !configured.isEmpty
    else { return }
    result.append(
      contentsOf: expandedExplicitWindowsPaths(
        configured,
        processArchitecture: processArchitecture
      ))
  }

  private static func appendOfficialInstallations(
    localAppData: String?,
    programFiles: String?,
    programFilesX86: String?,
    programW6432: String?,
    userProfile: String?,
    to result: inout [String]
  ) {
    if let localAppData {
      result.append(contentsOf: [
        WindowsPath.join(localAppData, "Programs", "OpenAI", "Codex", "bin", "codex.exe"),
        WindowsPath.join(localAppData, "Programs", "Codex", "bin", "codex.exe"),
        WindowsPath.join(localAppData, "Programs", "Codex", "resources", "codex.exe"),
        WindowsPath.join(localAppData, "Programs", "ChatGPT", "resources", "codex.exe"),
      ])
    }
    if let userProfile {
      result.append(
        WindowsPath.join(
          userProfile,
          ".codex",
          "packages",
          "standalone",
          "current",
          "bin",
          "codex.exe"
        )
      )
    }
    for root in WindowsPath.unique(
      [programW6432, programFiles, programFilesX86].compactMap { $0 }
    ) {
      result.append(contentsOf: [
        WindowsPath.join(root, "OpenAI", "Codex", "bin", "codex.exe"),
        WindowsPath.join(root, "OpenAI", "Codex", "codex.exe"),
        WindowsPath.join(root, "Codex", "bin", "codex.exe"),
        WindowsPath.join(root, "Codex", "codex.exe"),
      ])
    }
  }

  private static func packageRoots(
    appData: String?,
    localAppData: String?,
    userProfile: String?
  ) -> [String] {
    var roots: [String] = []
    if let appData {
      roots.append(WindowsPath.join(appData, "npm", "node_modules", "@openai", "codex"))
    }
    if let localAppData {
      for version in 5...10 {
        roots.append(
          WindowsPath.join(
            localAppData,
            "pnpm",
            "global",
            String(version),
            "node_modules",
            "@openai",
            "codex"
          )
        )
      }
    }
    if let userProfile {
      roots.append(
        WindowsPath.join(
          userProfile,
          ".bun",
          "install",
          "global",
          "node_modules",
          "@openai",
          "codex"
        )
      )
    }
    return WindowsPath.unique(roots)
  }

  private static func trustedPathDirectories(
    appData: String?,
    localAppData: String?,
    programFiles: String?,
    programFilesX86: String?,
    programW6432: String?,
    userProfile: String?
  ) -> [String] {
    var roots = [programW6432, programFiles, programFilesX86].compactMap { $0 }
    if let appData { roots.append(WindowsPath.join(appData, "npm")) }
    if let localAppData {
      roots.append(contentsOf: [
        WindowsPath.join(localAppData, "Programs"),
        WindowsPath.join(localAppData, "pnpm"),
      ])
    }
    if let userProfile {
      roots.append(contentsOf: [
        WindowsPath.join(userProfile, ".codex", "packages"),
        WindowsPath.join(userProfile, ".codex", "bin"),
        WindowsPath.join(userProfile, ".bun", "bin"),
        WindowsPath.join(userProfile, ".cargo", "bin"),
        WindowsPath.join(userProfile, ".local", "bin"),
      ])
    }
    return WindowsPath.unique(roots)
  }

  private static func macOSCandidateURLs() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
      home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
      URL(fileURLWithPath: "/usr/local/bin/codex"),
      home.appendingPathComponent(".local/bin/codex"),
      home.appendingPathComponent(".cargo/bin/codex"),
      home.appendingPathComponent(".npm-global/bin/codex"),
      home.appendingPathComponent(
        "Library/Application Support/codex-plusplus/backup/Codex.app/Contents/Resources/codex"
      ),
      URL(fileURLWithPath: "/usr/bin/codex"),
    ]
  }

  private static func architectures(
    for processArchitecture: PlatformArchitecture
  ) -> [PlatformArchitecture] {
    switch processArchitecture {
    case .arm64:
      return [.arm64, .amd64]
    case .amd64:
      return [.amd64]
    case .unknown:
      return []
    }
  }

  @usableFromInline
  static func defaultValidator(
    _ url: URL,
    _ processArchitecture: PlatformArchitecture
  ) -> Bool {
    #if canImport(WinSDK)
      return WindowsNativeExecutableValidator.isValid(
        url,
        processArchitecture: processArchitecture
      )
    #else
      return FileManager.default.isExecutableFile(atPath: url.path)
    #endif
  }
}

public struct GitExecutableResolver: Sendable {
  public typealias Validator = @Sendable (URL, PlatformArchitecture) -> Bool

  private let environment: [String: String]
  private let processArchitecture: PlatformArchitecture
  private let validator: Validator

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processArchitecture: PlatformArchitecture = TargetPlatformArchitecture.current,
    validator: @escaping Validator = GitExecutableResolver.defaultValidator
  ) {
    self.environment = environment
    self.processArchitecture = processArchitecture
    self.validator = validator
  }

  public func resolve(explicitURL: URL? = nil) -> URL? {
    #if canImport(WinSDK)
      let paths = Self.windowsResolutionCandidatePaths(
        explicitPath: explicitURL?.path,
        environment: environment
      )
      return ExecutableResolverSelection.firstValid(
        paths.map { URL(fileURLWithPath: $0) }
      ) {
        validator($0, processArchitecture)
      }
    #else
      if let explicitURL { return explicitURL }
      let candidates = [
        URL(fileURLWithPath: "/usr/bin/git"),
        URL(fileURLWithPath: "/opt/homebrew/bin/git"),
        URL(fileURLWithPath: "/usr/local/bin/git"),
      ]
      return ExecutableResolverSelection.firstValid(candidates) {
        validator($0, processArchitecture)
      }
    #endif
  }

  static func windowsResolutionCandidatePaths(
    explicitPath: String?,
    environment: [String: String]
  ) -> [String] {
    if let explicitPath { return [WindowsPath.normalize(explicitPath)] }
    return windowsCandidatePaths(environment: environment)
  }

  public static func windowsCandidatePaths(environment: [String: String]) -> [String] {
    let localAppData = WindowsPath.environmentValue("LOCALAPPDATA", in: environment)
    let programFiles = WindowsPath.environmentValue("ProgramFiles", in: environment)
    let programFilesX86 = WindowsPath.environmentValue("ProgramFiles(x86)", in: environment)
    let programW6432 = WindowsPath.environmentValue("ProgramW6432", in: environment)
    var result: [String] = []

    if let configured = WindowsPath.environmentValue(
      "CODEX_BRIDGE_GIT_EXECUTABLE",
      in: environment
    ), !configured.isEmpty {
      result.append(WindowsPath.normalize(configured))
    }
    for root in WindowsPath.unique(
      [programW6432, programFiles, programFilesX86].compactMap { $0 }
    ) {
      result.append(WindowsPath.join(root, "Git", "cmd", "git.exe"))
      result.append(WindowsPath.join(root, "Git", "bin", "git.exe"))
    }
    if let localAppData {
      result.append(WindowsPath.join(localAppData, "Programs", "Git", "cmd", "git.exe"))
      result.append(WindowsPath.join(localAppData, "Programs", "Git", "bin", "git.exe"))
    }

    let trustedRoots = WindowsPath.unique(
      [programW6432, programFiles, programFilesX86].compactMap { $0 }
        + [localAppData.map { WindowsPath.join($0, "Programs", "Git") }].compactMap { $0 }
    )
    let path = WindowsPath.environmentValue("PATH", in: environment) ?? ""
    for directory in WindowsPath.splitSearchPath(path) {
      guard WindowsPath.isContained(directory, inAny: trustedRoots) else { continue }
      result.append(WindowsPath.join(directory, "git.exe"))
    }
    return WindowsPath.unique(result)
  }

  @usableFromInline
  static func defaultValidator(
    _ url: URL,
    _ processArchitecture: PlatformArchitecture
  ) -> Bool {
    #if canImport(WinSDK)
      return WindowsNativeExecutableValidator.isValid(
        url,
        processArchitecture: processArchitecture
      )
    #else
      return FileManager.default.isExecutableFile(atPath: url.path)
    #endif
  }
}

public enum WindowsPath {
  public static func normalize(_ value: String) -> String {
    var result = value.replacingOccurrences(of: "/", with: "\\")
    while result.count > 3 && result.hasSuffix("\\") { result.removeLast() }
    return result
  }

  public static func join(_ components: String...) -> String {
    join(components)
  }

  public static func join(_ components: [String]) -> String {
    components.reduce("") { partial, component in
      let component = normalize(component)
      guard !component.isEmpty else { return partial }
      guard !partial.isEmpty else { return component }
      return normalize(partial) + "\\"
        + component.trimmingCharacters(
          in: CharacterSet(charactersIn: "\\")
        )
    }
  }

  public static func parent(_ value: String) -> String {
    let normalized = normalize(value)
    guard let index = normalized.lastIndex(of: "\\") else { return "" }
    if index == normalized.index(normalized.startIndex, offsetBy: 2),
      normalized.dropFirst().first == ":"
    {
      return String(normalized[...index])
    }
    return String(normalized[..<index])
  }

  public static func basename(_ value: String) -> String {
    normalize(value).split(separator: "\\").last.map(String.init) ?? ""
  }

  public static func splitSearchPath(_ value: String) -> [String] {
    var results: [String] = []
    var current = ""
    var quoted = false
    for character in value {
      if character == "\"" {
        quoted.toggle()
      } else if character == ";" && !quoted {
        appendSearchPath(current, to: &results)
        current.removeAll(keepingCapacity: true)
      } else {
        current.append(character)
      }
    }
    guard !quoted else { return [] }
    appendSearchPath(current, to: &results)
    return results
  }

  public static func isContained(_ candidate: String, inAny roots: [String]) -> Bool {
    let candidate = normalize(candidate).lowercased()
    return roots.contains { root in
      let root = normalize(root).lowercased()
      return candidate == root || candidate.hasPrefix(root + "\\")
    }
  }

  public static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
    normalize(lhs).caseInsensitiveCompare(normalize(rhs)) == .orderedSame
  }

  public static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let normalized = normalize(value)
      guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else {
        return nil
      }
      return normalized
    }
  }

  public static func environmentValue(
    _ key: String,
    in environment: [String: String]
  ) -> String? {
    if let value = environment[key] { return value }
    return environment.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
  }

  private static func appendSearchPath(_ value: String, to results: inout [String]) {
    let entry = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalize(entry)
    if !normalized.isEmpty { results.append(normalized) }
  }
}
