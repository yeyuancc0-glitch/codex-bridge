import BridgeSecurity
import Foundation
import WinSDK
import XCTest

final class SecureMutationWindowsTests: XCTestCase {
  func testResolverAndReaderCaptureRegularFileIdentityCaseInsensitively() throws {
    try withProjectRoot { rootURL, resolver in
      let file = rootURL.appendingPathComponent("MixedCase.txt")
      try Data("reader value\n".utf8).write(to: file)

      let path = try SecureRelativePath("mixedcase.txt")
      let resolved = try resolver.resolve(path)
      XCTAssertEqual(resolved.identity.kind, FileSystemIdentity.windowsFileID128Kind)
      let read = try SecureFileReader().read(path, through: resolver)
      XCTAssertEqual(read.text, "reader value\n")
    }
  }

  func testWriterCreatesNestedFileReplacesAtomicallyAndCleansStaging() throws {
    try withProjectRoot { rootURL, resolver in
      let writer = SecureProjectFileWriter()
      let path = try SecureRelativePath("nested/file name & symbols.txt")
      let first = Data("first value\n".utf8)
      let second = Data("second value\n".utf8)

      let created = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .create,
        content: first,
        expectedSHA256: nil,
        createParents: true
      )
      XCTAssertEqual(created.oldRevision, nil)
      XCTAssertEqual(created.newRevision, .digest(of: first))
      XCTAssertEqual(try writer.readContent(relativePath: path, through: resolver), first)

      let replaced = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .replace,
        content: second,
        expectedSHA256: created.newRevision.sha256,
        createParents: false
      )
      XCTAssertEqual(replaced.oldRevision, created.newRevision)
      XCTAssertEqual(replaced.newRevision, .digest(of: second))
      XCTAssertEqual(try writer.readContent(relativePath: path, through: resolver), second)
      XCTAssertFalse(try containsStagingFile(rootURL))
    }
  }

  func testCreateExistingAndRevisionConflictLeaveOriginalUntouched() throws {
    try withProjectRoot { rootURL, resolver in
      let writer = SecureProjectFileWriter()
      let path = try SecureRelativePath("file.txt")
      let original = Data("original\n".utf8)
      _ = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .create,
        content: original,
        expectedSHA256: nil,
        createParents: false
      )

      XCTAssertThrowsError(
        try writer.write(
          relativePath: path,
          through: resolver,
          mode: .create,
          content: Data("other\n".utf8),
          expectedSHA256: nil,
          createParents: false
        )
      ) { error in
        XCTAssertEqual(error as? PathSecurityError, .targetAlreadyExists)
      }
      XCTAssertThrowsError(
        try writer.write(
          relativePath: path,
          through: resolver,
          mode: .replace,
          content: Data("replacement\n".utf8),
          expectedSHA256: String(repeating: "0", count: 64),
          createParents: false
        )
      ) { error in
        XCTAssertEqual(error as? PathSecurityError, .revisionConflict)
      }
      XCTAssertEqual(try writer.readContent(relativePath: path, through: resolver), original)
      XCTAssertFalse(try containsStagingFile(rootURL))
    }
  }

  func testDirectoryMutationsMoveAndDeleteWithRevisionChecks() throws {
    try withProjectRoot { _, resolver in
      let writer = SecureProjectFileWriter()
      let mutation = SecureProjectDirectoryMutation()
      let directory = try SecureRelativePath("folder")
      _ = try mutation.apply(
        action: .createDirectory,
        relativePath: directory,
        destinationRelativePath: nil,
        through: resolver
      )

      let source = try SecureRelativePath("folder/source file.txt")
      let destination = try SecureRelativePath("folder/destination & file.txt")
      let content = Data("move me\n".utf8)
      let revision = try writer.write(
        relativePath: source,
        through: resolver,
        mode: .create,
        content: content,
        expectedSHA256: nil,
        createParents: false
      ).newRevision

      let moved = try mutation.apply(
        action: .moveFile(
          sourceExpectedSHA256: revision.sha256,
          destinationExpectedAbsent: true
        ),
        relativePath: source,
        destinationRelativePath: destination,
        through: resolver
      )
      XCTAssertEqual(moved.revision, revision)
      XCTAssertNil(try writer.readContent(relativePath: source, through: resolver))
      XCTAssertEqual(try writer.readContent(relativePath: destination, through: resolver), content)

      let deleted = try mutation.apply(
        action: .deleteFile(expectedSHA256: revision.sha256),
        relativePath: destination,
        destinationRelativePath: nil,
        through: resolver
      )
      XCTAssertEqual(deleted.revision, revision)
      XCTAssertNil(try writer.readContent(relativePath: destination, through: resolver))

      _ = try mutation.apply(
        action: .deleteEmptyDirectory,
        relativePath: directory,
        destinationRelativePath: nil,
        through: resolver
      )
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: rootPath(resolver).appendingPathComponent("folder").path
        )
      )
    }
  }

  func testHardLinkedFileCannotBeReplacedOrDeleted() throws {
    try withProjectRoot { rootURL, resolver in
      let writer = SecureProjectFileWriter()
      let mutation = SecureProjectDirectoryMutation()
      let path = try SecureRelativePath("primary.txt")
      let content = Data("linked\n".utf8)
      let revision = try writer.write(
        relativePath: path,
        through: resolver,
        mode: .create,
        content: content,
        expectedSHA256: nil,
        createParents: false
      ).newRevision
      let primary = rootURL.appendingPathComponent("primary.txt")
      let alias = rootURL.appendingPathComponent("alias.txt")
      guard createHardLink(link: alias.path, existing: primary.path) else {
        throw XCTSkip("CreateHardLinkW unavailable: \(GetLastError())")
      }

      XCTAssertThrowsError(
        try writer.write(
          relativePath: path,
          through: resolver,
          mode: .replace,
          content: Data("replacement\n".utf8),
          expectedSHA256: revision.sha256,
          createParents: false
        )
      ) { error in
        XCTAssertEqual(error as? PathSecurityError, .unsupportedHardLink)
      }
      XCTAssertThrowsError(
        try mutation.apply(
          action: .deleteFile(expectedSHA256: revision.sha256),
          relativePath: path,
          destinationRelativePath: nil,
          through: resolver
        )
      ) { error in
        XCTAssertEqual(error as? PathSecurityError, .unsupportedHardLink)
      }
    }
  }

  func testReparseParentIsRejectedWhenSymbolicLinksAreAvailable() throws {
    try withProjectRoot { rootURL, resolver in
      let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-bridge-outside-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: outside) }
      let link = rootURL.appendingPathComponent("linked", isDirectory: true)
      guard createDirectorySymbolicLink(link: link.path, target: outside.path) else {
        throw XCTSkip("Directory symbolic links require Developer Mode or privilege")
      }

      XCTAssertThrowsError(
        try SecureProjectFileWriter().write(
          relativePath: SecureRelativePath("linked/escape.txt"),
          through: resolver,
          mode: .create,
          content: Data("blocked\n".utf8),
          expectedSHA256: nil,
          createParents: false
        )
      ) { error in
        XCTAssertEqual(error as? PathSecurityError, .pathEscapeBlocked)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
    }
  }

  func testReparseRootRegistrationFailsClosedWhenSymbolicLinksAreAvailable() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-root-link-\(UUID().uuidString)", isDirectory: true)
    let target = parent.appendingPathComponent("target", isDirectory: true)
    let link = parent.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    guard createDirectorySymbolicLink(link: link.path, target: target.path) else {
      throw XCTSkip("Directory symbolic links require Developer Mode or privilege")
    }

    XCTAssertThrowsError(try RegisteredRoot(capturing: link)) { error in
      XCTAssertEqual(error as? PathSecurityError, .pathEscapeBlocked)
    }
  }

  func testRegisteredRootReplacementFailsClosed() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-root-swap-\(UUID().uuidString)", isDirectory: true)
    let rootURL = parent.appendingPathComponent("project", isDirectory: true)
    let movedURL = parent.appendingPathComponent("original", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let resolver = ProjectPathResolver(root: try RegisteredRoot(capturing: rootURL))
    try FileManager.default.moveItem(at: rootURL, to: movedURL)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)

    XCTAssertThrowsError(
      try SecureProjectFileWriter().write(
        relativePath: SecureRelativePath("blocked.txt"),
        through: resolver,
        mode: .create,
        content: Data("blocked\n".utf8),
        expectedSHA256: nil,
        createParents: false
      )
    ) { error in
      XCTAssertEqual(error as? PathSecurityError, .rootIdentityChanged)
    }
  }

  private func withProjectRoot(
    _ body: (URL, ProjectPathResolver) throws -> Void
  ) throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-bridge-security-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try body(rootURL, ProjectPathResolver(root: RegisteredRoot(capturing: rootURL)))
  }

  private func rootPath(_ resolver: ProjectPathResolver) -> URL {
    URL(fileURLWithPath: resolver.root.canonicalPath, isDirectory: true)
  }

  private func containsStagingFile(_ root: URL) throws -> Bool {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil
      )
    else { return false }
    while let value = enumerator.nextObject() {
      guard let url = value as? URL else { continue }
      if url.lastPathComponent.hasPrefix(".codexbridge.staging.") { return true }
    }
    return false
  }

  private func createHardLink(link: String, existing: String) -> Bool {
    withWide(link) { linkPath in
      withWide(existing) { existingPath in
        CreateHardLinkW(linkPath, existingPath, nil)
      }
    }
  }

  private func createDirectorySymbolicLink(link: String, target: String) -> Bool {
    let flags = DWORD(0x1 | 0x2)
    return withWide(link) { linkPath in
      withWide(target) { targetPath in
        CreateSymbolicLinkW(linkPath, targetPath, flags)
      }
    }
  }

  private func withWide<Result>(
    _ value: String,
    _ body: (UnsafePointer<WCHAR>) -> Result
  ) -> Result {
    var wide = Array(value.utf16)
    wide.append(0)
    return wide.withUnsafeBufferPointer { body($0.baseAddress!) }
  }
}
