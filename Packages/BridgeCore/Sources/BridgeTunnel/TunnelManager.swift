import BridgeSecurity
import Darwin
import Foundation

public actor TunnelManager {
  public typealias Now = @Sendable () -> Date

  private struct RunContext: Sendable {
    let id: UUID
    let name: String
    let root: TunnelDirectoryHandle
    let run: TunnelDirectoryHandle
    let directory: URL
    let socket: URL

    var hasExpectedIdentity: Bool {
      root.contains(name: name, directory: run)
    }
  }

  private let configuration: TunnelConfiguration
  private let secretStore: any SecretStore
  private let helperVerifier: TunnelHelperVerifier
  private let launcher = TunnelProcessLauncher()
  private let healthClient = UnixHealthClient()
  private let now: Now
  private let outputLimit = 128 * 1024
  private var lifecycle: TunnelLifecycle = .stopped
  private var process: TunnelSpawnedProcess?
  private var runContext: RunContext?
  private var monitor: Task<Void, Never>?
  private var doctorInProgress = false
  private var doctorProcess: TunnelSpawnedProcess?
  private var lastDiagnostics = TunnelDiagnostics(
    standardOutput: "",
    standardError: "",
    wasTruncated: false,
    actionRequired: false
  )

  public init(
    configuration: TunnelConfiguration,
    secretStore: any SecretStore,
    helperVerifier: TunnelHelperVerifier = TunnelHelperVerifier(),
    now: @escaping Now = Date.init
  ) {
    self.configuration = configuration
    self.secretStore = secretStore
    self.helperVerifier = helperVerifier
    self.now = now
  }

  public func state() -> TunnelLifecycle { lifecycle }

  public func acceptsRemoteSubmissions() -> Bool {
    lifecycle == .ready && !lastDiagnostics.actionRequired
  }

  public func diagnostics() -> TunnelDiagnostics {
    captureDiagnostics()
    return lastDiagnostics
  }

  public func doctor() async throws -> TunnelDoctorReport {
    guard lifecycle == .stopped || lifecycle == .failed else {
      throw TunnelManagerError.lifecycleBusy
    }
    guard !doctorInProgress else { throw TunnelManagerError.lifecycleBusy }
    doctorInProgress = true
    defer { doctorInProgress = false }
    let verifiedHelper = try helperVerifier.verify(
      executable: configuration.helperExecutable,
      expectedSHA256: configuration.expectedHelperSHA256
    )
    let key = try loadRuntimeKey()
    let context = try prepareRunContext()
    var cleanupFinished = false
    defer {
      if !cleanupFinished, !cleanup(context) { recordCleanupFailure() }
    }
    let child = try spawn(
      verifiedHelper: verifiedHelper,
      arguments: helperArguments(command: "doctor", context: context) + ["--json"],
      key: key,
      context: context
    )
    doctorProcess = child
    defer {
      if doctorProcess === child { doctorProcess = nil }
    }
    let exit: TunnelChildExit
    do {
      exit = try await waitForExit(child, timeout: configuration.processTimeout)
    } catch {
      await terminate(child)
      captureDiagnostics(from: child)
      throw error
    }
    let diagnostics = diagnostics(for: child)
    guard exit.code == 0 else {
      throw TunnelManagerError.doctorFailed(
        exitCode: exit.code,
        diagnostics: Self.combinedDiagnostics(diagnostics)
      )
    }
    let cleaned = cleanup(context)
    cleanupFinished = true
    guard cleaned else {
      recordCleanupFailure()
      throw TunnelManagerError.cleanupFailed
    }
    return TunnelDoctorReport(output: diagnostics.standardOutput)
  }

  public func start() async throws {
    guard !doctorInProgress else { throw TunnelManagerError.lifecycleBusy }
    guard lifecycle == .stopped || lifecycle == .failed else {
      throw TunnelManagerError.alreadyRunning
    }
    lifecycle = .starting
    do {
      let verifiedHelper = try helperVerifier.verify(
        executable: configuration.helperExecutable,
        expectedSHA256: configuration.expectedHelperSHA256
      )
      let key = try loadRuntimeKey()
      let context = try prepareRunContext()
      runContext = context
      lifecycle = .authenticating
      try await runDoctor(context: context, key: key, verifiedHelper: verifiedHelper)
      guard runContext?.id == context.id, lifecycle != .stopped else {
        throw TunnelManagerError.stopped
      }
      let child = try spawn(
        verifiedHelper: verifiedHelper,
        arguments: helperArguments(command: "run", context: context),
        key: key,
        context: context
      )
      process = child
      runContext = context
      try await waitUntilReady(runID: context.id)
      lifecycle = .ready
      beginMonitor(runID: context.id)
    } catch {
      if let child = process {
        await terminate(child)
        captureDiagnostics(from: child)
      }
      if let context = runContext, !cleanup(context) { recordCleanupFailure() }
      if lifecycle != .stopped { lifecycle = .failed }
      process = nil
      runContext = nil
      throw error
    }
  }

  public func stop() async {
    monitor?.cancel()
    monitor = nil
    let child = process
    let doctorChild = doctorProcess
    let context = runContext
    process = nil
    doctorProcess = nil
    runContext = nil
    lifecycle = .stopped
    if let child {
      await terminate(child)
      captureDiagnostics(from: child)
    }
    if let doctorChild, doctorChild !== child {
      await terminate(doctorChild)
      captureDiagnostics(from: doctorChild)
    }
    if let context, !cleanup(context) {
      recordCleanupFailure()
      lifecycle = .failed
    }
  }

  private func runDoctor(
    context: RunContext,
    key: Data,
    verifiedHelper: TunnelVerifiedHelper
  ) async throws {
    let child = try spawn(
      verifiedHelper: verifiedHelper,
      arguments: helperArguments(command: "doctor", context: context) + ["--json"],
      key: key,
      context: context
    )
    process = child
    let exit = try await waitForExit(child, timeout: configuration.processTimeout)
    guard process === child, runContext?.id == context.id, lifecycle != .stopped else {
      throw TunnelManagerError.stopped
    }
    if process === child { process = nil }
    let output = diagnostics(for: child)
    guard exit.code == 0 else {
      throw TunnelManagerError.doctorFailed(
        exitCode: exit.code,
        diagnostics: Self.combinedDiagnostics(output)
      )
    }
  }

  private func spawn(
    verifiedHelper: TunnelVerifiedHelper,
    arguments: [String],
    key: Data,
    context: RunContext
  ) throws -> TunnelSpawnedProcess {
    let keyText = String(decoding: key, as: UTF8.self)
    let urlText = configuration.localMCPURL.absoluteString
    let headerSecret = configuration.localMCPHeaderSecret
    guard context.hasExpectedIdentity else { throw TunnelManagerError.launchFailed }
    return try launcher.spawn(
      verifiedHelper: verifiedHelper,
      helperVerifier: helperVerifier,
      arguments: arguments,
      runtimeKey: key,
      localMCPHeaderSecret: Data(headerSecret.utf8),
      runtimeDirectory: context.directory,
      sensitiveValues: [keyText, urlText, headerSecret],
      outputLimit: outputLimit
    )
  }

  private func waitUntilReady(runID: UUID) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: configuration.readinessTimeout)
    while clock.now < deadline {
      guard runContext?.id == runID, let child = process else {
        throw TunnelManagerError.stopped
      }
      if let exit = child.pollExit() {
        captureDiagnostics(from: child)
        throw TunnelManagerError.helperExited(exitCode: exit.code)
      }
      captureDiagnostics(from: child)
      let health = healthState(child: child)
      if health.pollFresh { lifecycle = .connecting }
      if health.ready, !lastDiagnostics.actionRequired { return }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw TunnelManagerError.readinessTimedOut
  }

  private func beginMonitor(runID: UUID) {
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.configuration.healthInterval ?? .seconds(5))
        guard !Task.isCancelled else { return }
        await self?.inspectRun(runID: runID)
      }
    }
  }

  private func inspectRun(runID: UUID) {
    guard runContext?.id == runID, let child = process else { return }
    if child.pollExit() != nil {
      captureDiagnostics(from: child)
      lifecycle = .failed
      if let context = runContext, !cleanup(context) { recordCleanupFailure() }
      process = nil
      runContext = nil
      monitor?.cancel()
      monitor = nil
      return
    }
    captureDiagnostics(from: child)
    lifecycle =
      healthState(child: child).ready && !lastDiagnostics.actionRequired ? .ready : .degraded
  }

  private func healthState(child: TunnelSpawnedProcess) -> (pollFresh: Bool, ready: Bool) {
    guard let context = runContext, context.hasExpectedIdentity else { return (false, false) }
    guard
      let snapshot = try? healthClient.snapshot(
        socketPath: context.socket.path,
        expectedPeerPID: child.pid
      )
    else {
      return (false, false)
    }
    guard let timestamp = snapshot.pollTimestamp, timestamp > 0 else { return (false, false) }
    let age = now().timeIntervalSince1970 - timestamp
    let fresh = age >= -5 && age <= configuration.metricsFreshness.timeInterval
    return (fresh, fresh && snapshot.isReady)
  }

  private func loadRuntimeKey() throws -> Data {
    let key = try secretStore.load(configuration.runtimeKeyReference)
    guard let keyText = String(data: key, encoding: .utf8) else {
      throw TunnelManagerError.invalidRuntimeKey
    }
    let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    let bytes = Array(trimmed.utf8)
    guard !bytes.isEmpty, bytes.count <= 16 * 1024, bytes.allSatisfy(Self.isKeyByte) else {
      throw TunnelManagerError.invalidRuntimeKey
    }
    return Data(bytes)
  }

  private func prepareRunContext() throws -> RunContext {
    let root = try TunnelDirectoryHandle(existingRoot: configuration.runtimeDirectory)
    let id = UUID()
    let name = "r-\(id.uuidString.prefix(12))"
    let run = try TunnelDirectoryHandle(creating: name, in: root)
    let directory = URL(fileURLWithPath: run.path, isDirectory: true)
    let socket = directory.appendingPathComponent("health.sock")
    let context = RunContext(
      id: id,
      name: name,
      root: root,
      run: run,
      directory: directory,
      socket: socket
    )
    var succeeded = false
    defer {
      if !succeeded { _ = cleanup(context) }
    }
    try run.createDirectory(name: "codex-home")
    guard socket.path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
      throw TunnelManagerError.launchFailed
    }
    succeeded = true
    return context
  }

  private func helperArguments(command: String, context: RunContext) -> [String] {
    let directory = context.directory
    let urlFile = directory.appendingPathComponent("health.url").path
    let pidFile = directory.appendingPathComponent("tunnel.pid").path
    return [
      command,
      "--control-plane.tunnel-id", configuration.tunnelID.rawValue,
      "--control-plane.api-key=file:/dev/fd/3",
      "--mcp.server-url", configuration.helperMCPURL.absoluteString,
      "--mcp.extra-headers", "X-Codex-Bridge-Token: file:/dev/fd/4",
      "--health.unix-socket", context.socket.path,
      "--health.url-file", urlFile,
      "--pid.file", pidFile,
      "--allow-remote-ui=false",
      "--open-web-ui=false",
      "--log.level", "warn",
      "--log.format", "json",
    ]
  }

  private func waitForExit(
    _ child: TunnelSpawnedProcess,
    timeout: Duration
  ) async throws -> TunnelChildExit {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let exit = child.pollExit() { return exit }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw TunnelManagerError.processTimedOut
  }

  private func terminate(_ child: TunnelSpawnedProcess) async {
    guard child.beginTermination() else {
      _ = await exits(child, within: configuration.processTimeout + .seconds(2))
      return
    }
    if await exits(child, within: configuration.processTimeout) { return }
    child.escalateTermination()
    _ = await exits(child, within: .seconds(2))
  }

  private func cleanup(_ context: RunContext) -> Bool {
    guard context.hasExpectedIdentity else { return false }
    do {
      for name in [
        "observed.json", "health.sock", "health.url", "tunnel.pid",
      ] {
        try context.run.removeEntry(name: name)
      }
      try context.run.removeEntry(name: "codex-home", directory: true)
      guard context.root.contains(name: context.name, directory: context.run) else { return false }
      try context.root.removeEntry(name: context.name, directory: true)
      return true
    } catch {
      return false
    }
  }

  private func exits(_ child: TunnelSpawnedProcess, within duration: Duration) async -> Bool {
    await exit(child, within: duration) != nil
  }

  private func exit(
    _ child: TunnelSpawnedProcess,
    within duration: Duration
  ) async -> TunnelChildExit? {
    await Task.detached {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: duration)
      while clock.now < deadline {
        if let exit = child.pollExit() { return exit }
        usleep(50_000)
      }
      return child.pollExit()
    }.value
  }

  private func captureDiagnostics() {
    guard let process else { return }
    captureDiagnostics(from: process)
  }

  private func captureDiagnostics(from child: TunnelSpawnedProcess) {
    lastDiagnostics = diagnostics(for: child)
  }

  private func diagnostics(for child: TunnelSpawnedProcess) -> TunnelDiagnostics {
    let stdout = child.stdout.snapshot()
    let stderr = child.stderr.snapshot()
    return TunnelDiagnostics(
      standardOutput: stdout.text,
      standardError: stderr.text,
      wasTruncated: stdout.truncated || stderr.truncated,
      actionRequired: child.stdout.authenticationFailureObserved()
        || child.stderr.authenticationFailureObserved()
        || Self.requiresAuthenticationAction(stdout.text + "\n" + stderr.text)
    )
  }

  private static func requiresAuthenticationAction(_ text: String) -> Bool {
    let lower = text.lowercased()
    let compact = lower.filter { !$0.isWhitespace }
    return lower.contains("unauthorized") || lower.contains("forbidden")
      || compact.contains("\"status\":401") || compact.contains("\"status\":403")
      || compact.contains("\"status_code\":401") || compact.contains("\"status_code\":403")
  }

  private func recordCleanupFailure() {
    let stderr = [lastDiagnostics.standardError, "Tunnel runtime cleanup failed."]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    lastDiagnostics = TunnelDiagnostics(
      standardOutput: lastDiagnostics.standardOutput,
      standardError: stderr,
      wasTruncated: lastDiagnostics.wasTruncated,
      actionRequired: lastDiagnostics.actionRequired
    )
  }

  private static func combinedDiagnostics(_ diagnostics: TunnelDiagnostics) -> String {
    [diagnostics.standardOutput, diagnostics.standardError]
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private static func isKeyByte(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
      || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let parts = components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
