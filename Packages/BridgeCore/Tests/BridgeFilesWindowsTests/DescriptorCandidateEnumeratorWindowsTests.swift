#if canImport(WinSDK)
  import BridgeSecurity
  import Foundation
  import XCTest

  @testable import BridgeFiles

  final class DescriptorCandidateEnumeratorWindowsTests: XCTestCase {
    func testEnumeratesRegularFilesAndSkipsIgnoredTreesAndOversizedFiles() throws {
      let rootURL = try makeRoot()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      try write("z.txt", to: rootURL)
      try write("a.txt", to: rootURL)
      try write("Sources/main.swift", to: rootURL)
      try write(".git/config", to: rootURL)
      try write("node_modules/dependency.js", to: rootURL)
      try write(String(repeating: "x", count: 17), at: "large.bin", to: rootURL)

      let root = try RegisteredRoot(capturing: rootURL)
      let limits = try ProjectFileLimits(maximumFileBytes: 16)
      var enumerator = DescriptorCandidateEnumerator(
        root: root,
        policy: ProjectFilePolicy(forbiddenPatterns: []),
        limits: limits
      )

      let result = try enumerator.candidates(scope: nil)
      XCTAssertEqual(result.paths, ["a.txt", "Sources/main.swift", "z.txt"])
      XCTAssertFalse(result.usedTrackedPathPriority)
    }

    func testScopeUsesWindowsHandlesForRelativeDirectory() throws {
      let rootURL = try makeRoot()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      try write("Sources/a.swift", to: rootURL)
      try write("Tests/a.swift", to: rootURL)

      let root = try RegisteredRoot(capturing: rootURL)
      var enumerator = DescriptorCandidateEnumerator(
        root: root,
        policy: ProjectFilePolicy(forbiddenPatterns: []),
        limits: .default
      )
      let scope = try SecureRelativePath("Sources")

      let result = try enumerator.candidates(scope: scope)
      XCTAssertEqual(result.paths, ["Sources/a.swift"])
    }

    func testCandidateLimitFailsClosed() throws {
      let rootURL = try makeRoot()
      defer { try? FileManager.default.removeItem(at: rootURL) }
      try write("one.txt", to: rootURL)
      try write("two.txt", to: rootURL)

      let root = try RegisteredRoot(capturing: rootURL)
      let limits = try ProjectFileLimits(
        maximumCandidateFiles: 1,
        maximumEnumeratedEntries: 2
      )
      var enumerator = DescriptorCandidateEnumerator(
        root: root,
        policy: ProjectFilePolicy(forbiddenPatterns: []),
        limits: limits
      )

      XCTAssertThrowsError(try enumerator.candidates(scope: nil)) { error in
        XCTAssertEqual(error as? ProjectFileError, .candidateLimitExceeded)
      }
    }

    private func makeRoot() throws -> URL {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-files-windows-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
      )
      return root
    }

    private func write(_ relativePath: String, to root: URL) throws {
      try write("content", at: relativePath, to: root)
    }

    private func write(_ content: String, at relativePath: String, to root: URL) throws {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(content.utf8).write(to: url)
    }
  }
#endif
