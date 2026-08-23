#if canImport(WinSDK)
  import BridgeProcessRuntime
  import Foundation

  struct TunnelChildExit: Equatable, Sendable {
    let code: Int32
  }

  final class WindowsTunnelSpawnedProcess: @unchecked Sendable {
    let pid: UInt32
    let stdout: RedactedOutputBuffer
    let stderr: RedactedOutputBuffer
    private let process: WindowsJobProcess
    private let stdoutReader: WindowsTunnelOutputReader
    private let stderrReader: WindowsTunnelOutputReader
    private let lock = NSLock()
    private var terminationClaimed = false

    init(process: WindowsJobProcess, sensitiveValues: [String], outputLimit: Int) {
      self.process = process
      pid = process.processIdentifier
      stdout = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
      stderr = RedactedOutputBuffer(limit: outputLimit, sensitiveValues: sensitiveValues)
      stdoutReader = WindowsTunnelOutputReader(handle: process.standardOutput, buffer: stdout)
      stderrReader = WindowsTunnelOutputReader(handle: process.standardError, buffer: stderr)
      stdoutReader.start()
      stderrReader.start()
    }

    deinit {
      process.close()
    }

    func pollExit() -> TunnelChildExit? {
      guard !process.isRunning else { return nil }
      let code = process.waitForExit(timeout: .zero) ?? 255
      stdoutReader.finish()
      stderrReader.finish()
      return TunnelChildExit(code: code)
    }

    func beginTermination() -> Bool {
      lock.withLock {
        guard !terminationClaimed else { return false }
        terminationClaimed = true
        return process.terminateTree()
      }
    }

    func escalateTermination() {
      _ = process.terminateTree()
    }
  }

  struct WindowsTunnelProcessLauncher: Sendable {
    func spawn(
      verifiedHelper: WindowsTunnelVerifiedHelper,
      arguments: [String],
      runtimeKey: Data,
      localMCPHeaderSecret: Data,
      runtimeDirectory: URL,
      sensitiveValues: [String],
      outputLimit: Int
    ) throws -> WindowsTunnelSpawnedProcess {
      let directory = try WindowsSecureRunDirectory(existingRoot: runtimeDirectory)
      let runtimeKeyName = "runtime.key"
      let headerSecretName = "mcp-header.key"
      do {
        try directory.createRegularFile(name: runtimeKeyName, data: runtimeKey)
        try directory.createRegularFile(name: headerSecretName, data: localMCPHeaderSecret)
      } catch {
        try? directory.removeEntry(name: runtimeKeyName)
        try? directory.removeEntry(name: headerSecretName)
        throw TunnelManagerError.launchFailed
      }

      let rewritten = Self.rewriteSecretArguments(
        arguments,
        runtimeKeyPath: Self.join(directory.path, runtimeKeyName),
        headerSecretPath: Self.join(directory.path, headerSecretName)
      )
      guard let rewritten else {
        try? directory.removeEntry(name: runtimeKeyName)
        try? directory.removeEntry(name: headerSecretName)
        throw TunnelManagerError.launchFailed
      }

      let environment = Self.environment(runtimeDirectory: directory.path)
      do {
        let process = try WindowsJobProcess(
          configuration: WindowsJobProcessConfiguration(
            executableURL: verifiedHelper.executable,
            arguments: rewritten,
            currentDirectoryURL: runtimeDirectory,
            environment: environment,
            expectedExecutableIdentity: verifiedHelper.identity
          )
        )
        try? process.standardInput.close()
        return WindowsTunnelSpawnedProcess(
          process: process,
          sensitiveValues: sensitiveValues,
          outputLimit: outputLimit
        )
      } catch {
        try? directory.removeEntry(name: runtimeKeyName)
        try? directory.removeEntry(name: headerSecretName)
        throw TunnelManagerError.launchFailed
      }
    }

    static func rewriteSecretArguments(
      _ arguments: [String],
      runtimeKeyPath: String,
      headerSecretPath: String
    ) -> [String]? {
      var runtimeKeyReplaced = false
      var headerSecretReplaced = false
      let values = arguments.map { argument in
        if argument == "--control-plane.api-key=file:/dev/fd/3" {
          runtimeKeyReplaced = true
          return "--control-plane.api-key=file:\(runtimeKeyPath)"
        }
        if argument == "X-Codex-Bridge-Token: file:/dev/fd/4" {
          headerSecretReplaced = true
          return "X-Codex-Bridge-Token: file:\(headerSecretPath)"
        }
        return argument
      }
      return runtimeKeyReplaced && headerSecretReplaced ? values : nil
    }

    private static func environment(runtimeDirectory: String) -> [String: String] {
      let source = ProcessInfo.processInfo.environment
      var result = [
        "TEMP": runtimeDirectory,
        "TMP": runtimeDirectory,
        "CODEX_HOME": join(runtimeDirectory, "codex-home"),
      ]
      for name in ["SystemRoot", "WINDIR"] {
        if let value = source[name], !value.isEmpty { result[name] = value }
      }
      return result
    }

    private static func join(_ parent: String, _ name: String) -> String {
      parent.hasSuffix("\\") ? parent + name : parent + "\\" + name
    }
  }

  private final class WindowsTunnelOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let buffer: RedactedOutputBuffer
    private let lock = NSLock()
    private var finished = false

    init(handle: FileHandle, buffer: RedactedOutputBuffer) {
      self.handle = handle
      self.buffer = buffer
    }

    func start() {
      Task.detached(priority: .utility) { [self] in
        buffer.append(handle.readDataToEndOfFile())
        finish()
      }
    }

    func finish() {
      lock.withLock {
        guard !finished else { return }
        finished = true
        buffer.finish()
        try? handle.close()
      }
    }
  }
#endif
