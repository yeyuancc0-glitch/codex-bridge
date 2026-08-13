import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation
import XCTest

final class ProjectRegistryTests: XCTestCase {
  func testRegistrationGeneratesOpaqueIDAndPersistsNormalizedConfiguration() async throws {
    let scratch = try makeScratchDirectory()
    let repositoryURL = scratch.appending(path: "repository", directoryHint: .isDirectory)
    let projectURL = repositoryURL.appending(path: "Sources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let command = try VerificationCommand(executable: "/usr/bin/swift", arguments: ["test"])
    let forbidden = try ForbiddenPathPattern("Generated/**")
    let policy = ProjectAccessPolicy(
      read: .allowed, write: .allowed, network: .requiresLocalApproval)
    let registration = try LocalProjectRegistration(
      name: "  Bridge Core  ",
      rootURL: projectURL,
      repositoryRootURL: repositoryURL,
      accessPolicy: policy,
      verificationCommands: [command],
      forbiddenPatterns: [forbidden]
    )

    let first = try await registry.register(local: registration)
    let secondRoot = scratch.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let second = try await registry.register(
      local: LocalProjectRegistration(name: "Other", rootURL: secondRoot)
    )

    XCTAssertTrue(first.id.rawValue.hasPrefix("prj_"))
    XCTAssertEqual(first.id.rawValue.count, 36)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.name, "Bridge Core")
    XCTAssertEqual(first.capabilities, ProjectCapabilitiesDTO(policy: policy))

    let persisted = await repository.project(id: first.id)
    let stored = try XCTUnwrap(persisted)
    XCTAssertEqual(stored.primaryRoot.canonicalPath, projectURL.resolvingSymlinksInPath().path)
    XCTAssertEqual(
      stored.repositoryRoot.canonicalPath, repositoryURL.resolvingSymlinksInPath().path)
    XCTAssertNotEqual(stored.primaryRoot.identity.inode, 0)
    XCTAssertEqual(stored.verificationCommands, [command])
    XCTAssertEqual(stored.forbiddenPatterns, [forbidden])
  }

  func testAccessPolicyUpdatePersistsWithoutChangingProjectIdentity() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let summary = try await registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: root)
    )
    let originalValue = await repository.project(id: summary.id)
    let original = try XCTUnwrap(originalValue)
    let policy = ProjectAccessPolicy(
      read: .allowed,
      write: .denied,
      network: .requiresLocalApproval
    )

    try await registry.updateAccessPolicy(policy, for: summary.id)

    let updatedValue = await repository.project(id: summary.id)
    let updated = try XCTUnwrap(updatedValue)
    XCTAssertEqual(updated.accessPolicy, policy)
    XCTAssertEqual(updated.id, original.id)
    XCTAssertEqual(updated.primaryRoot, original.primaryRoot)
    XCTAssertEqual(updated.createdAt, original.createdAt)
  }

  func testDuplicateSymlinkedRootIsRejected() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    let alias = scratch.appending(path: "alias", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    _ = try await registry.register(local: LocalProjectRegistration(name: "Project", rootURL: root))

    await assertRegistryError(.duplicateRoot) {
      _ = try await registry.register(
        local: LocalProjectRegistration(name: "Alias", rootURL: alias)
      )
    }
  }

  func testRepositoryMustContainPrimaryRoot() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    let repositoryRoot = scratch.appending(
      path: "different-repository", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    await assertRegistryError(.repositoryDoesNotContainProject) {
      _ = try await registry.register(
        local: LocalProjectRegistration(
          name: "Project",
          rootURL: root,
          repositoryRootURL: repositoryRoot
        )
      )
    }
  }

  func testUnknownProjectAndPathEscapeAreRejected() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    let outside = scratch.appending(path: "outside", directoryHint: .isDirectory)
    let outsideFile = outside.appending(path: "secret.txt")
    let escape = root.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("secret".utf8).write(to: outsideFile)
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: root)
    )

    await assertRegistryError(.unknownProject) {
      _ = try await registry.summary(for: ProjectID(rawValue: "prj_unknown"))
    }

    do {
      _ = try await registry.resolvePrimaryPath(
        projectID: project.id,
        relativePath: SecureRelativePath("escape/secret.txt")
      )
      XCTFail("Expected the symlink escape to be rejected")
    } catch {
      XCTAssertEqual(error as? PathSecurityError, .pathEscapeBlocked)
    }

    XCTAssertThrowsError(try SecureRelativePath("../outside/secret.txt")) { error in
      guard case .invalidRelativePath = error as? PathSecurityError else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testExplicitWorktreeIsAnExactAllowedThreadRoot() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    let worktree = scratch.appending(path: "task-worktree", directoryHint: .isDirectory)
    let nested = worktree.appending(path: "Sources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let repository = InMemoryProjectRepository()
    let registry = ProjectRegistry(repository: repository)
    let project = try await registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: root)
    )
    try await registry.addExplicitWorktree(localRootURL: worktree, to: project.id)

    let matched = try await registry.validateThreadWorkingDirectory(worktree, for: project.id)
    XCTAssertEqual(matched.canonicalPath, worktree.resolvingSymlinksInPath().path)

    await assertRegistryError(.workingDirectoryOutsideProject) {
      _ = try await registry.validateThreadWorkingDirectory(nested, for: project.id)
    }

    let persisted = await repository.project(id: project.id)
    let stored = try XCTUnwrap(persisted)
    XCTAssertEqual(stored.worktreeRoots, [matched])
  }

  func testWorktreeRootCannotBeRegisteredTwiceAcrossProjects() async throws {
    let scratch = try makeScratchDirectory()
    let firstRoot = scratch.appending(path: "first", directoryHint: .isDirectory)
    let secondRoot = scratch.appending(path: "second", directoryHint: .isDirectory)
    let worktree = scratch.appending(path: "worktree", directoryHint: .isDirectory)
    for directory in [firstRoot, secondRoot, worktree] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let first = try await registry.register(
      local: LocalProjectRegistration(name: "First", rootURL: firstRoot)
    )
    let second = try await registry.register(
      local: LocalProjectRegistration(name: "Second", rootURL: secondRoot)
    )
    try await registry.addExplicitWorktree(localRootURL: worktree, to: first.id)

    await assertRegistryError(.duplicateRoot) {
      try await registry.addExplicitWorktree(localRootURL: worktree, to: second.id)
    }
  }

  func testReplacedRootFailsIdentityValidation() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "project", directoryHint: .isDirectory)
    let original = scratch.appending(path: "original-project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let project = try await registry.register(
      local: LocalProjectRegistration(name: "Project", rootURL: root)
    )
    try FileManager.default.moveItem(at: root, to: original)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    do {
      _ = try await registry.summary(for: project.id)
      XCTFail("Expected the replaced root to be rejected")
    } catch {
      XCTAssertEqual(error as? PathSecurityError, .rootIdentityChanged)
    }
  }

  func testMCPFacingSummaryDoesNotEncodeCanonicalPaths() async throws {
    let scratch = try makeScratchDirectory()
    let root = scratch.appending(path: "private-project-name", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let registry = ProjectRegistry(repository: InMemoryProjectRepository())
    let summary = try await registry.register(
      local: LocalProjectRegistration(name: "Public Name", rootURL: root)
    )
    let encoded = try JSONEncoder().encode(summary)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    XCTAssertEqual(Set(object.keys), ["id", "name", "capabilities"])
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(root.path))
  }

  func testInvalidCommandAndPatternAreRejectedAtConstruction() {
    XCTAssertThrowsError(try VerificationCommand(executable: "swift test" + "\n"))
    XCTAssertThrowsError(try VerificationCommand(executable: "swift", arguments: ["bad\0arg"]))
    XCTAssertThrowsError(try VerificationCommand(executable: "swift", arguments: ["bad\narg"]))
    XCTAssertThrowsError(try ForbiddenPathPattern(""))
    XCTAssertThrowsError(try ForbiddenPathPattern("../Generated/**"))
    XCTAssertThrowsError(try ForbiddenPathPattern("Generated/**suffix"))
  }

  func testDecodedConfigurationRevalidatesAndUnknownPermissionSurvives() throws {
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        VerificationCommand.self,
        from: Data(#"{"executable":"swift\ntest","arguments":[]}"#.utf8)
      )
    )
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        ForbiddenPathPattern.self,
        from: Data(#""../Secrets/**""#.utf8)
      )
    )

    let future = try JSONDecoder().decode(
      ProjectPermission.self,
      from: Data(#""futurePermission""#.utf8)
    )
    XCTAssertEqual(future.rawValue, "futurePermission")
    XCTAssertEqual(try JSONEncoder().encode(future), Data(#""futurePermission""#.utf8))
  }

  private func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "bridge-projects-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func assertRegistryError(
    _ expected: ProjectRegistryError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? ProjectRegistryError, expected)
    }
  }
}
