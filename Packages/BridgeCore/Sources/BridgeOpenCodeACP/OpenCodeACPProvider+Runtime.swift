import BridgeAgentCore
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension OpenCodeACPProvider {
  func makeRunDirectory(prefix: String) throws -> String {
    guard !prefix.isEmpty, prefix.utf8.count <= 64,
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
        attributes: Self.privateDirectoryAttributes
      )
      #if !os(Windows)
        guard chmod(path, 0o700) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      try Self.validatePrivateDirectory(path)
      return URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
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
      OpenCodeACPLaunchBuilder.removeRunDirectory(runDirectory)
    }
    if probeRoot.owned {
      OpenCodeACPLaunchBuilder.removeRunDirectory(probeRoot.path)
    }
  }

  private func prepareRuntimeBase() throws -> String {
    let value = configuration.runtimeBaseDirectory
    guard AgentPathSemantics.isAbsolute(value), !value.contains("\0"),
      value.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest("runtimeBaseDirectory")
    }
    let requested = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: Self.privateDirectoryAttributes
      )
      let canonical = URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
      #if !os(Windows)
        guard chmod(canonical, 0o700) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      try Self.validatePrivateDirectory(canonical)
      return canonical
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  func makePersistentStateDirectory(
    installation: AgentInstallation,
    request: AgentExecutionRequest
  ) throws -> String? {
    guard let configuredBase = configuration.persistentStateBaseDirectory else { return nil }
    let base = try preparePrivateDirectory(
      configuredBase,
      field: "persistentStateBaseDirectory"
    )
    let identity = [
      installation.providerID.rawValue,
      installation.id.rawValue,
      request.projectID.rawValue,
      request.projectRoot,
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return try preparePrivateDirectory(
      URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(digest, isDirectory: true).path,
      field: "persistentStateDirectory"
    )
  }

  private func preparePrivateDirectory(_ value: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(value), !value.contains("\0"),
      value.utf8.count <= 16 * 1_024
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    let requested = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
    do {
      try FileManager.default.createDirectory(
        atPath: requested,
        withIntermediateDirectories: true,
        attributes: Self.privateDirectoryAttributes
      )
      #if !os(Windows)
        guard chmod(requested, 0o700) == 0 else { throw AgentRuntimeError.processUnavailable }
      #endif
      try Self.validatePrivateDirectory(requested)
      let canonical = URL(fileURLWithPath: requested, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
      return canonical
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  private static func validatePrivateDirectory(_ path: String) throws {
    #if os(Windows)
      // Windows uses ACLs; only existence and directory type are portable checks.
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw AgentRuntimeError.processUnavailable
      }
    #else
      var metadata = stat()
      guard lstat(path, &metadata) == 0,
        metadata.st_uid == getuid(),
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_mode & 0o777 == 0o700
      else {
        throw AgentRuntimeError.processUnavailable
      }
    #endif
  }

  private static var privateDirectoryAttributes: [FileAttributeKey: Any]? {
    #if os(Windows)
      nil
    #else
      [.posixPermissions: 0o700]
    #endif
  }
}
