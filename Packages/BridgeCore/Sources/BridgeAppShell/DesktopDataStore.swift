import Darwin
import Foundation

enum DesktopDataStoreError: Error, Equatable {
  case invalidLocation
  case insecureDirectory
  case insecureDatabaseFile
  case systemFailure(Int32)
}

struct DesktopDataStore: Sendable {
  let directoryURL: URL
  let eventStoreURL: URL
  let applicationRepositoryURL: URL
  let supervisionLedgerURL: URL
  let supervisorHomeURL: URL
  let pipelinePreflightURL: URL
  let verificationAuthorizationURL: URL
  let gitPatchDirectoryURL: URL

  static func prepare(at requestedURL: URL) throws -> DesktopDataStore {
    guard requestedURL.isFileURL, requestedURL.path.hasPrefix("/") else {
      throw DesktopDataStoreError.invalidLocation
    }
    let directoryURL = requestedURL.standardizedFileURL
    try prepareDirectory(directoryURL)
    let eventStoreURL = directoryURL.appendingPathComponent(
      "task-events.sqlite", isDirectory: false)
    let repositoryURL = directoryURL.appendingPathComponent(
      "application.sqlite", isDirectory: false)
    try prepareDatabaseFile(eventStoreURL)
    try prepareDatabaseFile(repositoryURL)
    let supervisionURL = directoryURL.appendingPathComponent(
      "supervision-ledger.sqlite", isDirectory: false
    )
    try prepareDatabaseFile(supervisionURL)
    let supervisorHomeURL = directoryURL.appendingPathComponent(
      "supervisor-home", isDirectory: true
    )
    try prepareDirectory(supervisorHomeURL)
    return DesktopDataStore(
      directoryURL: directoryURL,
      eventStoreURL: eventStoreURL,
      applicationRepositoryURL: repositoryURL,
      supervisionLedgerURL: supervisionURL,
      supervisorHomeURL: supervisorHomeURL,
      pipelinePreflightURL: directoryURL.appendingPathComponent(
        "pipeline-preflight.json",
        isDirectory: false
      ),
      verificationAuthorizationURL: directoryURL.appendingPathComponent(
        "verification-authorizations.json",
        isDirectory: false
      ),
      gitPatchDirectoryURL: directoryURL.appendingPathComponent(
        "git-patches",
        isDirectory: true
      )
    )
  }

  private static func prepareDirectory(_ url: URL) throws {
    var metadata = stat()
    if lstat(url.path, &metadata) != 0 {
      guard errno == ENOENT else { throw DesktopDataStoreError.systemFailure(errno) }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
      } catch {
        throw DesktopDataStoreError.systemFailure(errno)
      }
      guard lstat(url.path, &metadata) == 0 else {
        throw DesktopDataStoreError.systemFailure(errno)
      }
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_mode & 0o777 == 0o700
    else {
      throw DesktopDataStoreError.insecureDirectory
    }
  }

  private static func prepareDatabaseFile(_ url: URL) throws {
    let flags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
    var descriptor = open(url.path, flags, S_IRUSR | S_IWUSR)
    if descriptor < 0, errno == EEXIST {
      descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      if errno == ELOOP { throw DesktopDataStoreError.insecureDatabaseFile }
      throw DesktopDataStoreError.systemFailure(errno)
    }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw DesktopDataStoreError.systemFailure(errno)
    }
    guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_mode & 0o777 == 0o600
    else {
      throw DesktopDataStoreError.insecureDatabaseFile
    }
  }
}
