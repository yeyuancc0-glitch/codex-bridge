import BridgeAgentCore
import Foundation

#if !os(Windows)
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #endif
#endif

enum DeepSeekHarnessACPPathSupport {
  static func absolute(_ value: String, field: String) throws -> String {
    guard AgentPathSemantics.isAbsolute(value), !value.contains("\0"),
      value.utf8.count <= 16 * 1_024,
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      let canonical = AgentPathSemantics.canonicalPath(value)
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return canonical
  }

  static func canonicalExistingDirectory(_ value: String, field: String) throws -> String {
    let requested = try absolute(value, field: field)
    let resolved = URL(fileURLWithPath: requested, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    guard let canonical = AgentPathSemantics.canonicalPath(resolved), isDirectory(canonical) else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return canonical
  }

  static func existingParentDirectory(of value: String) -> String? {
    guard let parent = AgentPathSemantics.directoryPath(of: value),
      let canonical = AgentPathSemantics.canonicalPath(parent),
      isDirectory(canonical)
    else {
      return nil
    }
    return canonical
  }

  static func preparePrivateDirectory(
    _ value: String,
    field: String,
    withIntermediateDirectories: Bool = true
  ) throws -> String {
    let requested = try absolute(value, field: field)
    guard AgentPathSemantics.directoryPath(of: requested) != nil else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    do {
      try createPrivateDirectory(
        requested,
        withIntermediateDirectories: withIntermediateDirectories
      )
      guard
        let resolved = AgentPathSemantics.canonicalPath(
          URL(fileURLWithPath: requested, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        )
      else {
        throw AgentRuntimeError.processUnavailable
      }
      #if os(Windows)
        guard samePath(resolved, requested) else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
      return resolved
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  static func createPrivateDirectory(
    _ path: String,
    withIntermediateDirectories: Bool = true
  ) throws {
    do {
      #if os(Windows)
        try FileManager.default.createDirectory(
          atPath: path,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: nil
        )
        guard isDirectory(path),
          let resolved = AgentPathSemantics.canonicalPath(
            URL(fileURLWithPath: path, isDirectory: true)
              .resolvingSymlinksInPath().standardizedFileURL.path
          ),
          samePath(resolved, path)
        else {
          // Windows uses ACLs; Foundation creation retains the current user's ACL.
          throw AgentRuntimeError.processUnavailable
        }
      #else
        try FileManager.default.createDirectory(
          atPath: path,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
        guard chmod(path, 0o700) == 0 else {
          throw AgentRuntimeError.processUnavailable
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
          metadata.st_uid == getuid(),
          metadata.st_mode & S_IFMT == S_IFDIR,
          metadata.st_mode & 0o777 == 0o700
        else {
          throw AgentRuntimeError.processUnavailable
        }
      #endif
    } catch let error as AgentRuntimeError {
      throw error
    } catch {
      throw AgentRuntimeError.processUnavailable
    }
  }

  static func append(_ component: String, to parent: String, isDirectory: Bool = false) throws
    -> String
  {
    try append([component], to: parent, isDirectory: isDirectory)
  }

  static func append(
    _ components: [String],
    to parent: String,
    isDirectory: Bool = false
  ) throws -> String {
    var url = URL(fileURLWithPath: parent, isDirectory: true)
    for component in components {
      url.appendPathComponent(component, isDirectory: isDirectory && component == components.last)
    }
    guard let canonical = AgentPathSemantics.canonicalPath(url.path) else {
      throw AgentRuntimeError.processUnavailable
    }
    return canonical
  }

  static func approvalRelativePath(_ value: String, projectRoot: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 1_024,
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return nil
    }
    if AgentPathSemantics.isAbsolute(value) {
      guard let canonical = AgentPathSemantics.canonicalPath(value),
        let relative = AgentPathSemantics.relativePath(canonical, from: projectRoot),
        let components = AgentPathSemantics.relativeComponents(relative)
      else {
        return nil
      }
      return components.joined(separator: "/")
    }
    guard let components = AgentPathSemantics.relativeComponents(value) else { return nil }
    return components.joined(separator: "/")
  }

  static func samePath(_ lhs: String, _ rhs: String) -> Bool {
    AgentPathSemantics.isContained(lhs, in: rhs)
      && AgentPathSemantics.isContained(rhs, in: lhs)
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
