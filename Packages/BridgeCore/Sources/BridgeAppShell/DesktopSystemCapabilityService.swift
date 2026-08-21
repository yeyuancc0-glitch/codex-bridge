import BridgeCodexRPC
import BridgePresentation
import Darwin
import Foundation
import Security

struct DesktopSystemInspection: Sendable {
  let checks: [OnboardingCheckPresentation]
  let account: GetAccountResponse?
  let client: CodexAppServerClient?

  var requiredChecksPassed: Bool {
    checks.filter { $0.id != "tunnel-helper" }.allSatisfy { $0.status == .ready }
  }
}

protocol DesktopSystemCapabilityInspecting: Sendable {
  func inspect() async -> DesktopSystemInspection
}

struct DesktopSystemCapabilityService: DesktopSystemCapabilityInspecting {
  private static let openAITeamIdentifier = "2DC432GLL2"
  private let codexExecutableURL: URL?

  init(codexExecutableURL: URL? = nil) {
    self.codexExecutableURL = codexExecutableURL
  }

  func inspect() async -> DesktopSystemInspection {
    var checks = [operatingSystemCheck(), architectureCheck(), gitCheck()]
    checks.append(localPortCheck())
    checks.append(tunnelHelperCheck())
    guard let executable = codexExecutableURL ?? Self.resolveCodexExecutable() else {
      checks.append(
        check(
          id: "codex",
          title: "Codex CLI 未找到",
          detail: "请安装官方 Codex CLI，或让 Bridge 在后续版本中选择其绝对路径。",
          status: .blocked
        )
      )
      checks.append(contentsOf: unavailableAppServerChecks())
      return ordered(checks: checks, account: nil, client: nil)
    }

    checks.append(
      check(
        id: "codex",
        title: "Codex CLI 可用",
        detail: executable.path,
        status: .ready
      )
    )
    let client = CodexAppServerClient(
      configuration: .codex(executableURL: executable),
      defaultTimeoutNanoseconds: 10_000_000_000
    )
    do {
      let initialized = try await startAndInitialize(client)
      checks.append(
        check(
          id: "app-server",
          title: "Codex app-server 可启动",
          detail: initialized.userAgent,
          status: .ready
        )
      )
      let account = try await client.readAccount()
      checks.append(
        check(
          id: "account-method",
          title: "账号接口可用",
          detail: "account/read 已通过当前 app-server 响应。",
          status: .ready
        )
      )
      let models = try await client.listModels(ModelListParams(limit: 100))
      checks.append(
        check(
          id: "models",
          title: "模型目录可用",
          detail: "动态读取到 \(models.data.count) 个可见模型。",
          status: models.data.isEmpty ? .blocked : .ready
        )
      )
      return ordered(checks: checks, account: account, client: client)
    } catch {
      await client.stop()
      checks.append(
        check(
          id: "app-server",
          title: "Codex app-server 检测失败",
          detail: "无法完成 initialize、账号或模型能力协商。",
          status: .blocked
        )
      )
      checks.append(
        check(
          id: "account-method",
          title: "账号接口尚不可用",
          detail: "先修复 app-server initialize。",
          status: .blocked
        )
      )
      checks.append(
        check(
          id: "models",
          title: "模型目录尚不可用",
          detail: "先修复 app-server initialize。",
          status: .blocked
        )
      )
      return ordered(checks: checks, account: nil, client: nil)
    }
  }

  private func startAndInitialize(_ client: CodexAppServerClient) async throws
    -> InitializeResponse
  {
    try await client.start()
    return try await client.initialize(clientInfo: .bridge(version: "0.1.0"))
  }

  private func operatingSystemCheck() -> OnboardingCheckPresentation {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let supported = version.majorVersion >= 14
    return check(
      id: "macos",
      title: supported ? "macOS 版本受支持" : "macOS 版本过低",
      detail: ProcessInfo.processInfo.operatingSystemVersionString,
      status: supported ? .ready : .blocked
    )
  }

  private func architectureCheck() -> OnboardingCheckPresentation {
    #if arch(arm64)
      let architecture = "Apple Silicon (arm64)"
    #elseif arch(x86_64)
      let architecture = "Intel (x86_64)"
    #else
      let architecture = "不受支持的 CPU 架构"
    #endif
    #if arch(arm64) || arch(x86_64)
      let status = OnboardingItemStatus.ready
    #else
      let status = OnboardingItemStatus.blocked
    #endif
    return check(id: "architecture", title: "CPU 架构", detail: architecture, status: status)
  }

  private func gitCheck() -> OnboardingCheckPresentation {
    let path = "/usr/bin/git"
    let available = FileManager.default.isExecutableFile(atPath: path)
    return check(
      id: "git",
      title: available ? "Git 可用" : "Git 不可用",
      detail: available ? path : "未找到固定系统 Git。",
      status: available ? .ready : .blocked
    )
  }

  private func localPortCheck() -> OnboardingCheckPresentation {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      return check(
        id: "local-mcp-port",
        title: "本地 MCP 端口不可用",
        detail: "无法创建回环监听 socket。",
        status: .blocked
      )
    }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return check(
      id: "local-mcp-port",
      title: result == 0 ? "本地 MCP 可绑定回环端口" : "本地 MCP 端口检测失败",
      detail: result == 0 ? "127.0.0.1 动态端口可用。" : "无法绑定 127.0.0.1 动态端口。",
      status: result == 0 ? .ready : .blocked
    )
  }

  private func tunnelHelperCheck() -> OnboardingCheckPresentation {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tunnel-client"),
      Bundle.main.resourceURL?.appendingPathComponent("tunnel-client"),
    ].compactMap { $0 }
    let available = candidates.contains {
      FileManager.default.isExecutableFile(atPath: $0.path)
    }
    return check(
      id: "tunnel-helper",
      title: available ? "Tunnel helper 已打包" : "Tunnel helper 尚未打包",
      detail: available
        ? "连接测试仍会校验签名后 SHA-256 与动态代码身份。"
        : "当前开发构建可继续本机模式；Secure Tunnel 测试会保持阻断。",
      status: available ? .ready : .warning
    )
  }

  private func unavailableAppServerChecks() -> [OnboardingCheckPresentation] {
    [
      check(
        id: "app-server",
        title: "Codex app-server 尚不可用",
        detail: "未找到 Codex CLI。",
        status: .blocked
      ),
      check(
        id: "account-method",
        title: "账号接口尚不可用",
        detail: "未找到 Codex CLI。",
        status: .blocked
      ),
      check(
        id: "models",
        title: "模型目录尚不可用",
        detail: "未找到 Codex CLI。",
        status: .blocked
      ),
    ]
  }

  private func ordered(
    checks: [OnboardingCheckPresentation],
    account: GetAccountResponse?,
    client: CodexAppServerClient?
  ) -> DesktopSystemInspection {
    let order = [
      "macos", "architecture", "codex", "git", "app-server", "account-method", "models",
      "local-mcp-port", "tunnel-helper",
    ]
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return DesktopSystemInspection(
      checks: checks.sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] },
      account: account,
      client: client
    )
  }

  private func check(
    id: String,
    title: String,
    detail: String,
    status: OnboardingItemStatus
  ) -> OnboardingCheckPresentation {
    OnboardingCheckPresentation(id: id, title: title, detail: detail, status: status)
  }

  private static func resolveCodexExecutable() -> URL? {
    let pathEntries =
      ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":", omittingEmptySubsequences: true)
      .prefix(128)
      .map(String.init) ?? []
    let pathCandidates = pathEntries.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("codex")
    }
    let candidates =
      [
        URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Applications/ChatGPT.app/Contents/Resources/codex"
        ),
      ] + pathCandidates + [
        URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        URL(fileURLWithPath: "/usr/local/bin/codex"),
      ]
    return candidates.lazy.compactMap(validatedExecutable).first
  }

  static func validatedExecutable(_ candidate: URL) -> URL? {
    guard candidate.isFileURL, candidate.path.hasPrefix("/"),
      candidate.path.utf8.count <= 16_384,
      FileManager.default.isExecutableFile(atPath: candidate.path)
    else {
      return nil
    }
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    var metadata = stat()
    guard lstat(resolved.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      return nil
    }
    guard hasOfficialSignature(resolved) else { return nil }
    return resolved
  }

  private static func hasOfficialSignature(_ executable: URL) -> Bool {
    var requirement: SecRequirement?
    let source =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(openAITeamIdentifier)\""
    guard
      SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else {
      return false
    }
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
      let code
    else {
      return false
    }
    let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }
}
