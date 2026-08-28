import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension DeepSeekHarnessACPArtifactRuntime {
  static func nodeVersion(at path: String) throws -> String {
    let process = Process()
    let output = Pipe()
    let completion = DispatchSemaphore(value: 0)
    let captured = DeepSeekHarnessACPBoundedNodeVersionOutput(maximumBytes: 4 * 1_024)
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

  private static func terminateProcessGroup(_ processID: Int32, signal: Int32) {
    if kill(-processID, signal) != 0 {
      _ = kill(processID, signal)
    }
  }
}

private final class DeepSeekHarnessACPBoundedNodeVersionOutput: @unchecked Sendable {
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
