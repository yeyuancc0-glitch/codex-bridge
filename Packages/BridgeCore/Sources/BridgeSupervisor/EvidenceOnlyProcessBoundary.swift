import BridgeCodexRPC
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public enum EvidenceOnlyProcessBoundaryError: Error, Equatable, Sendable {
  case invalidPath(String)
  case profileTooLarge
  case unavailable
}

/// Builds a Seatbelt-wrapped app-server configuration for Supervisor-only work.
/// The caller must create and own the isolated HOME directory for the lifetime of
/// the process. No project or user-directory content is made available to it.
#if canImport(Darwin)
  public enum EvidenceOnlyProcessBoundary {
    public static let sandboxExecutableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    public static let maximumProfileBytes = 32 * 1024

    private static let sessionHomePrefix = "session-"

    /// Creates a private HOME for one Supervisor app-server session.
    ///
    /// The desktop data root is deliberately treated as a directory rather than
    /// as a shared HOME. Keeping each session in its own child prevents Codex
    /// configuration, caches, and transient files from crossing task boundaries.
    static func prepareSessionHome(in rootURL: URL) throws -> URL {
      let root = try privateDirectory(rootURL, field: "isolatedHomeRoot")
      let child = root.appendingPathComponent(
        sessionHomePrefix + UUID().uuidString.lowercased(),
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(
          at: child,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
      } catch {
        throw EvidenceOnlyProcessBoundaryError.unavailable
      }
      do {
        _ = try privateDirectory(child, field: "isolatedHome")
      } catch {
        try? FileManager.default.removeItem(at: child)
        throw error
      }
      return child
    }

    /// Removes only a private session directory created below the supplied root.
    /// A replaced symlink or non-directory is left untouched.
    static func removeSessionHome(_ homeURL: URL, from rootURL: URL) {
      let root = rootURL.standardizedFileURL.path
      let home = homeURL.standardizedFileURL.path
      guard home.hasPrefix(root + "/"),
        URL(fileURLWithPath: home).lastPathComponent.hasPrefix(sessionHomePrefix)
      else { return }

      guard hasPrivateDirectoryMetadata(atPath: root),
        hasPrivateDirectoryMetadata(atPath: home)
      else { return }
      try? FileManager.default.removeItem(atPath: home)
    }

    public static func configuration(
      wrapping base: AppServerConfiguration,
      isolatedHomeURL: URL,
      deniedReadRoots: [URL],
      networkAccess: Bool = false
    ) throws -> AppServerConfiguration {
      guard FileManager.default.fileExists(atPath: sandboxExecutableURL.path) else {
        throw EvidenceOnlyProcessBoundaryError.unavailable
      }
      let isolatedHome = try normalizedPath(isolatedHomeURL, field: "isolatedHome")
      let deniedRoots = try Set(
        deniedReadRoots.map {
          try normalizedPath($0, field: "deniedReadRoot")
        }
      )
      guard !deniedRoots.contains(where: { isolatedHome == $0 || isolatedHome.hasPrefix($0 + "/") })
      else {
        throw EvidenceOnlyProcessBoundaryError.invalidPath("isolatedHome")
      }
      let executableDirectory = base.executableURL.deletingLastPathComponent().path
      let protectedRoots = deniedRoots.union(["/Users"])
      guard
        !protectedRoots.contains(where: {
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
        isolatedHome: isolatedHome,
        networkAccess: networkAccess
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

    package static func isPrivateDirectory(_ url: URL) -> Bool {
      guard url.isFileURL else { return false }
      return hasPrivateDirectoryMetadata(atPath: url.standardizedFileURL.path)
    }

    private static func makeProfile(
      allowedReadRoots: Set<String>,
      deniedReadRoots: Set<String>,
      isolatedHome: String,
      networkAccess: Bool
    ) throws -> String {
      let allowReads = try allowedReadRoots.sorted().map { path in
        "(subpath \(try profileLiteral(path)))"
      }.joined(separator: " ")
      let denyReads = try deniedReadRoots.sorted().map { path in
        "(subpath \(try profileLiteral(path)))"
      }.joined(separator: " ")
      let home = try profileLiteral(isolatedHome)
      let userOutsideHome = "(require-all (subpath \"/Users\") (require-not (subpath \(home))))"
      let parent = try profileLiteral(
        URL(fileURLWithPath: isolatedHome).deletingLastPathComponent().path
      )
      let networkRule = networkAccess ? "(allow network-outbound)" : "(deny network*)"
      return """
        (version 1)
        (import "system.sb")
        (allow process*)
        \(networkRule)
        (allow file-read* \(allowReads))
        (allow file-read-metadata (subpath "/private") (subpath "/private/var")
          (subpath "/private/var/folders") (subpath "/private/var/select") (subpath \(parent)))
        (allow file-write* (subpath \(home)))
        (deny file-read* \(userOutsideHome))
        (deny file-write* \(userOutsideHome))
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

    private static func privateDirectory(_ url: URL, field: String) throws -> URL {
      let path = try normalizedPath(url, field: field)
      guard hasPrivateDirectoryMetadata(atPath: path) else {
        throw EvidenceOnlyProcessBoundaryError.invalidPath(field)
      }
      return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func hasPrivateDirectoryMetadata(atPath path: String) -> Bool {
      var metadata = stat()
      return lstat(path, &metadata) == 0
        && metadata.st_uid == getuid()
        && metadata.st_mode & S_IFMT == S_IFDIR
        && metadata.st_mode & 0o777 == 0o700
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
#else
  public enum EvidenceOnlyProcessBoundary {
    public static let sandboxExecutableURL = URL(fileURLWithPath: "")
    public static let maximumProfileBytes = 32 * 1024

    static func prepareSessionHome(in rootURL: URL) throws -> URL {
      _ = rootURL
      throw EvidenceOnlyProcessBoundaryError.unavailable
    }

    static func removeSessionHome(_ homeURL: URL, from rootURL: URL) {
      _ = (homeURL, rootURL)
    }

    public static func configuration(
      wrapping base: AppServerConfiguration,
      isolatedHomeURL: URL,
      deniedReadRoots: [URL],
      networkAccess: Bool = false
    ) throws -> AppServerConfiguration {
      _ = (base, isolatedHomeURL, deniedReadRoots, networkAccess)
      throw EvidenceOnlyProcessBoundaryError.unavailable
    }

    package static func isPrivateDirectory(_ url: URL) -> Bool {
      _ = url
      return false
    }
  }
#endif
