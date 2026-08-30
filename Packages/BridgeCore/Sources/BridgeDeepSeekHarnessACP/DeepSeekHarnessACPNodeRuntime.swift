import BridgeAgentCore
import BridgeProcess
import Foundation

extension DeepSeekHarnessACPArtifactRuntime {
  static func nodeVersion(at path: String) throws -> String {
    let captured = BoundedProcessOutputCollector(maximumBytes: 4 * 1_024)
    let process: ManagedStdioProcess
    do {
      process = try ManagedStdioProcess(
        argv: [path, "--version"],
        workingDirectory: nil,
        environment: nodeVersionEnvironment(path: path),
        mergeStandardError: false,
        onStandardOutput: captured.append
      )
    } catch {
      throw DeepSeekHarnessACPError.processUnavailable
    }
    process.closeStdin()

    guard let termination = process.waitForExit(timeout: .seconds(5)) else {
      _ = process.terminateAndWait(gracePeriod: .seconds(1), killWait: .seconds(1))
      process.drainRemainingOutput()
      process.close()
      throw DeepSeekHarnessACPError.processUnavailable
    }
    process.drainRemainingOutput()
    process.close()

    switch termination {
    case .exited(0):
      break
    case .exited(let status), .killed(let status):
      throw DeepSeekHarnessACPError.processExited(status)
    case .notStarted:
      throw DeepSeekHarnessACPError.processUnavailable
    }

    let output = captured.snapshot()
    guard !output.truncated else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible("oversized")
    }
    let value = output.tail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count <= 128, !value.contains("\0") else {
      throw DeepSeekHarnessACPError.nodeVersionIncompatible(value)
    }
    return value
  }

  private static func nodeVersionEnvironment(path: String) -> [String: String] {
    let directory = AgentPathSemantics.directoryPath(of: path) ?? path
    var environment = [
      "PATH": AgentPathSemantics.joinPathList([directory])
    ]
    #if os(Windows)
      let source = ProcessInfo.processInfo.environment
      for key in ["SystemRoot", "SystemDrive", "ComSpec"] {
        if let value = source.first(where: {
          $0.key.caseInsensitiveCompare(key) == .orderedSame
        })?.value,
          !value.isEmpty,
          !value.contains("\0")
        {
          environment[key] = value
        }
      }
    #endif
    return environment
  }
}
