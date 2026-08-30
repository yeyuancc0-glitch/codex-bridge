#if os(Windows)
  import Foundation

  enum CodexWindowsArchitecture: Sendable {
    case amd64
    case arm64

    static var current: Self {
      #if arch(arm64)
        return .arm64
      #else
        return .amd64
      #endif
    }

    var nativePackageName: String {
      switch self {
      case .amd64: "codex-win32-x64"
      case .arm64: "codex-win32-arm64"
      }
    }

    var vendorTriple: String {
      switch self {
      case .amd64: "x86_64-pc-windows-msvc"
      case .arm64: "aarch64-pc-windows-msvc"
      }
    }

    func accepts(machine: UInt16) -> Bool {
      switch self {
      case .amd64:
        machine == 0x8664
      case .arm64:
        machine == 0xAA64 || machine == 0xA641
      }
    }
  }

  struct CodexExecutableResolver: Sendable {
    typealias Validator = @Sendable (String, CodexWindowsArchitecture) -> Bool
    typealias RegularFileCheck = @Sendable (String) -> Bool

    private let environment: [String: String]
    private let architecture: CodexWindowsArchitecture
    private let validator: Validator
    private let regularFileCheck: RegularFileCheck

    init(
      environment: [String: String] = ProcessInfo.processInfo.environment,
      architecture: CodexWindowsArchitecture = .current,
      validator: @escaping Validator = CodexWindowsNativeExecutable.isValid,
      regularFileCheck: @escaping RegularFileCheck = CodexWindowsNativeExecutable.isRegularFile
    ) {
      self.environment = environment
      self.architecture = architecture
      self.validator = validator
      self.regularFileCheck = regularFileCheck
    }

    func resolve(explicitPath: String? = nil) -> String? {
      let candidates = explicitPath.map(expandedExplicitPaths) ?? candidatePaths()
      return CodexWindowsPath.unique(candidates).first(where: {
        validator($0, architecture)
      })
    }

    private func expandedExplicitPaths(_ path: String) -> [String] {
      guard let normalized = CodexWindowsPath.normalize(path) else { return [] }
      if normalized.lowercased().hasSuffix(".exe") { return [normalized] }
      guard normalized.lowercased().hasSuffix(".cmd"),
        CodexWindowsPath.basename(normalized)?.lowercased() == "codex.cmd",
        regularFileCheck(normalized),
        let directory = CodexWindowsPath.parent(normalized)
      else {
        return []
      }
      return nativeCodexPaths(
        packageRoot: CodexWindowsPath.join(directory, "node_modules", "@openai", "codex")
      )
    }

    private func candidatePaths() -> [String] {
      let appData = CodexWindowsPath.environmentValue("APPDATA", in: environment)
      let localAppData = CodexWindowsPath.environmentValue("LOCALAPPDATA", in: environment)
      let programFiles = CodexWindowsPath.environmentValue("ProgramFiles", in: environment)
      let programFilesX86 = CodexWindowsPath.environmentValue("ProgramFiles(x86)", in: environment)
      let programW6432 = CodexWindowsPath.environmentValue("ProgramW6432", in: environment)
      let userProfile = CodexWindowsPath.environmentValue("USERPROFILE", in: environment)
      var result: [String] = []

      if let configured = CodexWindowsPath.environmentValue(
        "CODEX_BRIDGE_CODEX_EXECUTABLE", in: environment
      ) {
        result.append(contentsOf: expandedExplicitPaths(configured))
      }
      appendOfficialInstallations(
        localAppData: localAppData,
        programFiles: programFiles,
        programFilesX86: programFilesX86,
        programW6432: programW6432,
        userProfile: userProfile,
        to: &result
      )
      result.append(
        contentsOf: packageExecutables(
          appData: appData,
          localAppData: localAppData,
          userProfile: userProfile
        ))
      result.append(
        contentsOf: pathExecutables(
          path: CodexWindowsPath.environmentValue("PATH", in: environment) ?? ""
        ))
      return result
    }

    private func appendOfficialInstallations(
      localAppData: String?,
      programFiles: String?,
      programFilesX86: String?,
      programW6432: String?,
      userProfile: String?,
      to result: inout [String]
    ) {
      if let localAppData {
        result.append(contentsOf: [
          CodexWindowsPath.join(localAppData, "Programs", "OpenAI", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "Codex", "resources", "codex.exe"),
          CodexWindowsPath.join(localAppData, "Programs", "ChatGPT", "resources", "codex.exe"),
        ])
      }
      if let userProfile {
        result.append(
          CodexWindowsPath.join(
            userProfile,
            ".codex",
            "packages",
            "standalone",
            "current",
            "bin",
            "codex.exe"
          ))
      }
      for root in [programW6432, programFiles, programFilesX86].compactMap({ $0 }) {
        result.append(contentsOf: [
          CodexWindowsPath.join(root, "OpenAI", "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(root, "OpenAI", "Codex", "codex.exe"),
          CodexWindowsPath.join(root, "Codex", "bin", "codex.exe"),
          CodexWindowsPath.join(root, "Codex", "codex.exe"),
        ])
      }
    }

    private func packageExecutables(
      appData: String?,
      localAppData: String?,
      userProfile: String?
    ) -> [String] {
      var roots: [String] = []
      var result: [String] = []
      if let appData {
        let npmDirectory = CodexWindowsPath.join(appData, "npm")
        result.append(CodexWindowsPath.join(npmDirectory, "codex.exe"))
        roots.append(CodexWindowsPath.join(appData, "npm", "node_modules", "@openai", "codex"))
      }
      if let localAppData {
        result.append(CodexWindowsPath.join(localAppData, "pnpm", "codex.exe"))
        for version in 5...10 {
          roots.append(
            CodexWindowsPath.join(
              localAppData,
              "pnpm",
              "global",
              String(version),
              "node_modules",
              "@openai",
              "codex"
            ))
        }
      }
      if let userProfile {
        result.append(
          CodexWindowsPath.join(
            userProfile,
            ".bun",
            "bin",
            "codex.exe"
          ))
        roots.append(
          CodexWindowsPath.join(
            userProfile,
            ".bun",
            "install",
            "global",
            "node_modules",
            "@openai",
            "codex"
          ))
      }
      result.append(contentsOf: roots.flatMap { nativeCodexPaths(packageRoot: $0) })
      return result
    }

    private func pathExecutables(path: String) -> [String] {
      CodexWindowsPath.splitSearchPath(path).flatMap { directory in
        var result = [CodexWindowsPath.join(directory, "codex.exe")]
        let shim = CodexWindowsPath.join(directory, "codex.cmd")
        guard regularFileCheck(shim) else { return result }
        let packageRoot = CodexWindowsPath.join(directory, "node_modules", "@openai", "codex")
        result.append(contentsOf: nativeCodexPaths(packageRoot: packageRoot))
        if let parent = CodexWindowsPath.parent(directory) {
          result.append(
            contentsOf: nativeCodexPaths(
              packageRoot: CodexWindowsPath.join(parent, "node_modules", "@openai", "codex")
            ))
        }
        return result
      }
    }

    private func nativeCodexPaths(packageRoot: String) -> [String] {
      let nativeRoot = CodexWindowsPath.join(
        packageRoot,
        "node_modules",
        "@openai",
        architecture.nativePackageName
      )
      let siblingRoot = CodexWindowsPath.parent(packageRoot).map {
        CodexWindowsPath.join($0, architecture.nativePackageName)
      }
      return [
        CodexWindowsPath.join(nativeRoot, "vendor", architecture.vendorTriple, "bin", "codex.exe"),
        siblingRoot.map {
          CodexWindowsPath.join($0, "vendor", architecture.vendorTriple, "bin", "codex.exe")
        },
        CodexWindowsPath.join(packageRoot, "vendor", architecture.vendorTriple, "bin", "codex.exe"),
      ].compactMap { $0 }
    }
  }
#endif
