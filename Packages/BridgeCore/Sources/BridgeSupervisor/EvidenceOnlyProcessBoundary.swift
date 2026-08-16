import BridgeCodexRPC
import Foundation

public enum EvidenceOnlyProcessBoundaryError: Error, Equatable, Sendable {
  case invalidPath(String)
  case profileTooLarge
  case unavailable
}

/// Builds a Seatbelt-wrapped app-server configuration for Supervisor-only work.
/// The caller must create and own the isolated HOME directory for the lifetime of
/// the process. No project or user-directory content is made available to it.
public enum EvidenceOnlyProcessBoundary {
  public static let sandboxExecutableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
  public static let maximumProfileBytes = 32 * 1024

  public static func configuration(
    wrapping base: AppServerConfiguration,
    isolatedHomeURL: URL,
    deniedReadRoots: [URL]
  ) throws -> AppServerConfiguration {
    guard FileManager.default.fileExists(atPath: sandboxExecutableURL.path) else {
      throw EvidenceOnlyProcessBoundaryError.unavailable
    }
    let isolatedHome = try normalizedPath(isolatedHomeURL, field: "isolatedHome")
    let deniedRoots = try Set(
      ["/Users"]
        + deniedReadRoots.map {
          try normalizedPath($0, field: "deniedReadRoot")
        }
    )
    guard !deniedRoots.contains(where: { isolatedHome == $0 || isolatedHome.hasPrefix($0 + "/") })
    else {
      throw EvidenceOnlyProcessBoundaryError.invalidPath("isolatedHome")
    }
    let executableDirectory = base.executableURL.deletingLastPathComponent().path
    guard
      !deniedRoots.contains(where: {
        executableDirectory == $0 || executableDirectory.hasPrefix($0 + "/")
      })
    else {
      throw EvidenceOnlyProcessBoundaryError.invalidPath("executable")
    }
    let allowedReads = Set([
      "/Applications/ChatGPT.app",
      "/Library",
      "/System",
      "/bin",
      "/usr",
      isolatedHome,
      executableDirectory,
    ])
    let profile = try makeProfile(
      allowedReadRoots: allowedReads,
      deniedReadRoots: deniedRoots,
      isolatedHome: isolatedHome
    )
    guard profile.utf8.count <= maximumProfileBytes else {
      throw EvidenceOnlyProcessBoundaryError.profileTooLarge
    }

    var environment = base.environment ?? [:]
    environment["HOME"] = isolatedHome
    environment["CODEX_HOME"] = isolatedHome
    if environment["PATH"] == nil {
      environment["PATH"] = "/usr/bin:/bin:/Applications/ChatGPT.app/Contents/Resources"
    }
    return AppServerConfiguration(
      executableURL: sandboxExecutableURL,
      arguments: ["-p", profile, base.executableURL.path] + base.arguments,
      currentDirectoryURL: isolatedHomeURL,
      environment: environment,
      maximumProtocolLineBytes: base.maximumProtocolLineBytes,
      stderrBufferBytes: base.stderrBufferBytes
    )
  }

  private static func makeProfile(
    allowedReadRoots: Set<String>,
    deniedReadRoots: Set<String>,
    isolatedHome: String
  ) throws -> String {
    let allowReads = try allowedReadRoots.sorted().map { path in
      "(subpath \(try profileLiteral(path)))"
    }.joined(separator: " ")
    let denyReads = try deniedReadRoots.sorted().map { path in
      "(subpath \(try profileLiteral(path)))"
    }.joined(separator: " ")
    let home = try profileLiteral(isolatedHome)
    let parent = try profileLiteral(
      URL(fileURLWithPath: isolatedHome).deletingLastPathComponent().path
    )
    return """
      (version 1)
      (import "system.sb")
      (allow process*)
      (deny network*)
      (allow file-read* \(allowReads))
      (allow file-read-metadata (subpath "/private") (subpath "/private/var")
        (subpath "/private/var/folders") (subpath "/private/var/select") (subpath \(parent)))
      (allow file-write* (subpath \(home)))
      (deny file-read* \(denyReads))
      (deny file-write* \(denyReads))
      """
  }

  private static func normalizedPath(_ url: URL, field: String) throws -> String {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw EvidenceOnlyProcessBoundaryError.invalidPath(field)
    }
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/"), !path.contains("\""), !path.contains("\\") else {
      throw EvidenceOnlyProcessBoundaryError.invalidPath(field)
    }
    return path
  }

  private static func profileLiteral(_ value: String) throws -> String {
    guard !value.isEmpty, !value.contains("\0"), !value.contains("\""),
      !value.contains("\\"),
      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else {
      throw EvidenceOnlyProcessBoundaryError.invalidPath("profile")
    }
    return "\"\(value)\""
  }
}
