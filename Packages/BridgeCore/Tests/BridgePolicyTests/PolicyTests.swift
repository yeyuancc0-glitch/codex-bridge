import BridgeProjects
import BridgeSecurity
import XCTest

@testable import BridgePolicy

final class PolicyTests: XCTestCase {
  func testTrustedReadsAndConfiguredVerificationAreAllowed() throws {
    let policy = CommandPolicy()
    let context = CommandPolicyContext(
      accessPolicy: .init(read: .allowed, write: .allowed, network: .requiresLocalApproval),
      verificationCommands: [
        try VerificationCommand(
          executable: "swift", arguments: ["test", "--filter", "UnitTests"])
      ]
    )

    XCTAssertEqual(
      policy.evaluate(
        argv: ["/usr/bin/git", "status"], networkRequested: false, context: context),
      PolicyDecision(.allow, reason: .trustedReadOnly)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["swift", "test", "--filter", "UnitTests"],
        networkRequested: false,
        context: context
      ),
      PolicyDecision(.allow, reason: .configuredVerification)
    )
  }

  func testGitWriteNetworkAndInstallRequireLocalApproval() {
    let policy = CommandPolicy()
    let context = allowedContext

    XCTAssertEqual(
      policy.evaluate(argv: ["git", "push"], networkRequested: false, context: context),
      PolicyDecision(.requireLocalApproval, reason: .gitWrite)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["curl", "https://example.com"], networkRequested: false, context: context),
      PolicyDecision(.requireLocalApproval, reason: .networkAccess)
    )
    XCTAssertEqual(
      policy.evaluate(argv: ["npm", "install"], networkRequested: false, context: context),
      PolicyDecision(.requireLocalApproval, reason: .packageInstallation)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["git", "branch", "-D", "old"], networkRequested: false, context: context),
      PolicyDecision(.requireLocalApproval, reason: .gitWrite)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["git", "diff", "--no-index", "/etc/passwd", "README.md"],
        networkRequested: false,
        context: context
      ),
      PolicyDecision(.requireLocalApproval, reason: .gitWrite)
    )
  }

  func testDestructiveSystemAndCredentialCommandsAreDenied() {
    let policy = CommandPolicy()
    let context = allowedContext

    XCTAssertEqual(
      policy.evaluate(
        argv: ["rm", "-rf", "build"], networkRequested: false, context: context),
      PolicyDecision(.deny, reason: .destructiveOperation)
    )
    XCTAssertEqual(
      policy.evaluate(argv: ["sudo", "true"], networkRequested: false, context: context),
      PolicyDecision(.deny, reason: .systemWrite)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["security", "find-generic-password"], networkRequested: false, context: context),
      PolicyDecision(.deny, reason: .credentialAccess)
    )
  }

  func testFileChangesEnforceSensitiveScopeAndLimits() throws {
    let policy = FileChangePolicy(
      limits: FileChangeLimits(maximumFiles: 2, maximumBytes: 32)
    )
    let sources = try SecureRelativePath("Sources")

    XCTAssertEqual(
      policy.evaluate(
        FileChangeRequest(
          paths: [try SecureRelativePath("Sources/App.swift")],
          totalBytes: 16
        ),
        allowedPathPrefixes: [sources],
        accessPolicy: allowedContext.accessPolicy,
        forbiddenPatterns: []
      ),
      PolicyDecision(.allow, reason: .projectWrite)
    )
    XCTAssertEqual(
      policy.evaluate(
        FileChangeRequest(paths: [try SecureRelativePath(".env")], totalBytes: 1),
        allowedPathPrefixes: [],
        accessPolicy: allowedContext.accessPolicy,
        forbiddenPatterns: []
      ),
      PolicyDecision(.deny, reason: .sensitivePath)
    )
    XCTAssertEqual(
      policy.evaluate(
        FileChangeRequest(paths: [try SecureRelativePath("README.md")], totalBytes: 1),
        allowedPathPrefixes: [sources],
        accessPolicy: allowedContext.accessPolicy,
        forbiddenPatterns: []
      ),
      PolicyDecision(.deny, reason: .outsideAllowedPath)
    )
    XCTAssertEqual(
      policy.evaluate(
        FileChangeRequest(
          paths: [try SecureRelativePath("Sources/Large.swift")],
          totalBytes: 33
        ),
        allowedPathPrefixes: [sources],
        accessPolicy: allowedContext.accessPolicy,
        forbiddenPatterns: []
      ),
      PolicyDecision(.requireLocalApproval, reason: .sizeLimit)
    )
  }

  func testExecutableIdentityAndGitBranchSyntaxCannotMasqueradeAsReadOnly() {
    let policy = CommandPolicy()

    for argv in [
      ["git", "status"], ["./git", "status"], ["/tmp/pwd"],
      ["git", "branch", "feature"],
    ] {
      XCTAssertEqual(
        policy.evaluate(argv: argv, networkRequested: false, context: allowedContext),
        PolicyDecision(
          .requireLocalApproval,
          reason: argv == ["git", "branch", "feature"] ? .gitWrite : .unsupportedCommand)
      )
    }
  }

  func testProjectPermissionsAreAnUpperBound() throws {
    let policy = CommandPolicy()
    let denied = CommandPolicyContext(
      accessPolicy: .init(read: .denied, write: .denied, network: .denied),
      verificationCommands: [try VerificationCommand(executable: "swift", arguments: ["test"])]
    )

    XCTAssertEqual(
      policy.evaluate(argv: ["/usr/bin/git", "status"], networkRequested: false, context: denied),
      PolicyDecision(.deny, reason: .projectReadDenied)
    )
    XCTAssertEqual(
      policy.evaluate(argv: ["swift", "test"], networkRequested: false, context: denied),
      PolicyDecision(.deny, reason: .projectReadDenied)
    )
    XCTAssertEqual(
      policy.evaluate(
        argv: ["curl", "https://example.com"], networkRequested: true, context: denied),
      PolicyDecision(.deny, reason: .projectNetworkDenied)
    )
  }

  func testShellWrapperCannotBecomeAutoApprovedVerification() throws {
    let policy = CommandPolicy()
    let context = CommandPolicyContext(
      accessPolicy: .init(read: .allowed, write: .allowed, network: .allowed),
      verificationCommands: [
        try VerificationCommand(executable: "sh", arguments: ["-c", "rm -rf /"])
      ]
    )

    XCTAssertEqual(
      policy.evaluate(
        argv: ["sh", "-c", "rm -rf /"], networkRequested: false, context: context),
      PolicyDecision(.requireLocalApproval, reason: .unsupportedCommand)
    )
  }

  func testForbiddenPatternsAndWritePermissionApplyToFileChanges() throws {
    let policy = FileChangePolicy()
    let generated = try ForbiddenPathPattern("Generated/**")
    let source = FileChangeRequest(
      paths: [try SecureRelativePath("Sources/App.swift")], totalBytes: 1)

    XCTAssertEqual(
      policy.evaluate(
        FileChangeRequest(
          paths: [try SecureRelativePath("Generated/Output.swift")], totalBytes: 1),
        allowedPathPrefixes: [],
        accessPolicy: .init(read: .allowed, write: .allowed, network: .denied),
        forbiddenPatterns: [generated]
      ),
      PolicyDecision(.deny, reason: .forbiddenPath)
    )
    XCTAssertEqual(
      policy.evaluate(
        source,
        allowedPathPrefixes: [],
        accessPolicy: .init(read: .allowed, write: .requiresLocalApproval, network: .denied),
        forbiddenPatterns: []
      ),
      PolicyDecision(.requireLocalApproval, reason: .projectWrite)
    )
    XCTAssertEqual(
      policy.evaluate(
        source,
        allowedPathPrefixes: [],
        accessPolicy: .init(read: .allowed, write: .denied, network: .denied),
        forbiddenPatterns: []
      ),
      PolicyDecision(.deny, reason: .projectWriteDenied)
    )
  }

  private var allowedContext: CommandPolicyContext {
    CommandPolicyContext(
      accessPolicy: .init(read: .allowed, write: .allowed, network: .requiresLocalApproval)
    )
  }
}
