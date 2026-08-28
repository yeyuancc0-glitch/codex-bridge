import BridgeAgentCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension DeepSeekHarnessACPProvider {
  func makeRunDirectory(prefix: String) throws -> String {
    guard !prefix.isEmpty,
      prefix.utf8.count <= 64,
      prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw AgentRuntimeError.invalidRequest("runtime.prefix")
    }
    let base = try prepareRuntimeBase()
    let path = URL(fileURLWithPath: base, isDirectory: true)
      .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
      .path
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(path, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  func makeProbeRoot(_ requested: String?) throws -> ProbeRoot {
    if let requested {
      return ProbeRoot(path: requested, owned: false)
    }
    let path = try makeRunDirectory(prefix: "probe-project")
    return ProbeRoot(path: path, owned: true)
  }

  func cleanup(runDirectory: String?, probeRoot: ProbeRoot) {
    if let runDirectory {
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(runDirectory)
    }
    if probeRoot.owned {
      DeepSeekHarnessACPLaunchBuilder.removeRunDirectory(probeRoot.path)
    }
  }

  private func prepareRuntimeBase() throws -> String {
    let value = configuration.runtimeBaseDirectory
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let path = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(path, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func validatePrivateDirectory(_ path: String) throws {
    var metadata = stat()
    guard lstat(path, &metadata) == 0,
      metadata.st_uid == getuid(),
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      throw AgentRuntimeError.processUnavailable
    }
  }
}

struct ProbeRoot: Sendable {
  let path: String
  let owned: Bool
}
