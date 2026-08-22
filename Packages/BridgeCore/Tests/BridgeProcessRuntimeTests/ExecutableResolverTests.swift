import BridgePlatform
import Foundation
import XCTest

@testable import BridgeProcessRuntime

final class ExecutableResolverTests: XCTestCase {
  func testCodexArm64CandidatesPreferNativeBeforeX64Fallback() {
    let candidates = CodexExecutableResolver.nativeCodexPaths(
      packageRoot: #"C:\Users\me\AppData\Roaming\npm\node_modules\@openai\codex"#,
      processArchitecture: .arm64
    )

    XCTAssertTrue(candidates.first?.contains("codex-win32-arm64") == true)
    let firstX64 = candidates.firstIndex { $0.contains("codex-win32-x64") }
    let lastArm64 = candidates.lastIndex { $0.contains("codex-win32-arm64") }
    XCTAssertNotNil(firstX64)
    XCTAssertNotNil(lastArm64)
    XCTAssertLessThan(lastArm64!, firstX64!)
  }

  func testControlledCodexCmdShimResolvesOnlyToNativePackageBinary() {
    let candidates = CodexExecutableResolver.expandedExplicitWindowsPaths(
      #"C:\Users\me\AppData\Roaming\npm\codex.cmd"#,
      processArchitecture: .amd64
    )

    XCTAssertFalse(candidates.isEmpty)
    XCTAssertTrue(candidates.allSatisfy { $0.lowercased().hasSuffix("codex.exe") })
    XCTAssertTrue(candidates.allSatisfy { !$0.lowercased().hasSuffix(".cmd") })
    XCTAssertTrue(candidates.contains { $0.contains("codex-win32-x64") })
    XCTAssertEqual(
      CodexExecutableResolver.expandedExplicitWindowsPaths(
        #"C:\tools\arbitrary.cmd"#,
        processArchitecture: .amd64
      ),
      []
    )
    XCTAssertEqual(
      CodexExecutableResolver.expandedExplicitWindowsPaths(
        #"C:\tools\codex.bat"#,
        processArchitecture: .amd64
      ),
      []
    )
  }

  func testExplicitCodexPathNeverFallsBackToDiscoveredInstallations() {
    let environment = [
      "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#,
      "ProgramFiles": #"C:\Program Files"#,
    ]
    let explicit = #"C:\Managed Tools\Codex\codex.exe"#

    XCTAssertEqual(
      CodexExecutableResolver.windowsResolutionCandidatePaths(
        explicitPath: explicit,
        environment: environment,
        processArchitecture: .amd64
      ),
      [explicit]
    )
    XCTAssertEqual(
      CodexExecutableResolver.windowsResolutionCandidatePaths(
        explicitPath: #"C:\Managed Tools\Codex\arbitrary.cmd"#,
        environment: environment,
        processArchitecture: .amd64
      ),
      []
    )
  }

  func testExplicitGitPathNeverFallsBackToDiscoveredInstallations() {
    let explicit = #"C:\Managed Tools\Git\git.exe"#
    XCTAssertEqual(
      GitExecutableResolver.windowsResolutionCandidatePaths(
        explicitPath: explicit,
        environment: ["ProgramFiles": #"C:\Program Files"#]
      ),
      [explicit]
    )
  }

  func testCandidateSearchIgnoresProjectControlledAndUntrustedPathEntries() {
    let environment = [
      "APPDATA": #"C:\Users\me\AppData\Roaming"#,
      "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#,
      "ProgramFiles": #"C:\Program Files"#,
      "USERPROFILE": #"C:\Users\me"#,
      "PATH":
        #"D:\project\bin;C:\Users\me\AppData\Local\Microsoft\WinGet\Links;C:\Users\me\AppData\Roaming\npm"#,
    ]

    let candidates = CodexExecutableResolver.windowsCandidatePaths(
      environment: environment,
      processArchitecture: .amd64
    )

    XCTAssertFalse(candidates.contains { $0.lowercased().hasPrefix(#"d:\project"#) })
    XCTAssertFalse(candidates.contains { $0.lowercased().contains(#"\winget\links\"#) })
    XCTAssertTrue(
      candidates.contains {
        $0.lowercased() == #"c:\users\me\appdata\roaming\npm\codex.exe"#
      })
  }

  func testOfficialStandaloneInstallPrecedesPackageAndPathCandidates() {
    let environment = [
      "APPDATA": #"C:\Users\me\AppData\Roaming"#,
      "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#,
      "ProgramFiles": #"C:\Program Files"#,
      "USERPROFILE": #"C:\Users\me"#,
      "PATH": #"C:\Users\me\.codex\bin;C:\Users\me\AppData\Roaming\npm"#,
    ]
    let candidates = CodexExecutableResolver.windowsCandidatePaths(
      environment: environment,
      processArchitecture: .amd64
    )

    XCTAssertEqual(
      candidates.first,
      #"C:\Users\me\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"#
    )
    let standalone = candidates.firstIndex {
      WindowsPath.equivalent(
        $0,
        #"C:\Users\me\.codex\packages\standalone\current\bin\codex.exe"#
      )
    }
    let npmNative = candidates.firstIndex {
      $0.lowercased().contains(#"\appdata\roaming\npm\node_modules\@openai\codex"#)
        && $0.lowercased().contains("codex-win32-x64")
    }
    XCTAssertNotNil(standalone)
    XCTAssertNotNil(npmNative)
    if let standalone, let npmNative {
      XCTAssertLessThan(standalone, npmNative)
    }
  }

  func testConfiguredCodexExecutableHasHighestPriority() {
    let configured = #"C:\Managed Tools\Codex\codex.exe"#
    let candidates = CodexExecutableResolver.windowsCandidatePaths(
      environment: [
        "CODEX_BRIDGE_CODEX_EXECUTABLE": configured,
        "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#,
      ],
      processArchitecture: .amd64
    )

    XCTAssertEqual(candidates.first, configured)
  }

  func testGitResolverUsesStandardInstallAndIgnoresUntrustedPathFallback() {
    let environment = [
      "LOCALAPPDATA": #"C:\Users\me\AppData\Local"#,
      "ProgramFiles": #"C:\Program Files"#,
      "PATH": #"C:\Users\me\AppData\Local\Microsoft\WinGet\Links"#,
    ]
    let candidates = GitExecutableResolver.windowsCandidatePaths(environment: environment)

    XCTAssertEqual(candidates.first, #"C:\Program Files\Git\cmd\git.exe"#)
    XCTAssertFalse(candidates.contains { $0.lowercased().contains(#"\winget\links\"#) })
  }

  func testWindowsSearchPathParserPreservesQuotedSemicolons() {
    XCTAssertEqual(
      WindowsPath.splitSearchPath(#""C:\Program Files\Tool;Bundle";C:\Tools"#),
      [#"C:\Program Files\Tool;Bundle"#, #"C:\Tools"#]
    )
  }

  func testWindowsSearchPathParserRejectsUnbalancedQuotes() {
    XCTAssertEqual(
      WindowsPath.splitSearchPath(#""C:\Program Files\Tool;Bundle;C:\Tools"#),
      []
    )
  }

  func testWindowsPathNormalizationDoesNotRewriteWhitespaceOrExtendedPrefixes() {
    XCTAssertEqual(
      WindowsPath.normalize(#" C:\Managed Tools\codex.exe "#),
      #" C:\Managed Tools\codex.exe "#
    )
    XCTAssertEqual(
      WindowsPath.normalize(#"\\?\C:\Managed Tools\codex.exe"#),
      #"\\?\C:\Managed Tools\codex.exe"#
    )
  }

  func testSelectionPreservesPriorityAndDeduplicatesCaseInsensitively() {
    let first = URL(fileURLWithPath: "/tmp/One")
    let duplicate = URL(fileURLWithPath: "/tmp/one")
    let second = URL(fileURLWithPath: "/tmp/Two")
    var inspected: [String] = []

    let result = ExecutableResolverSelection.firstValid([first, duplicate, second]) { url in
      inspected.append(url.path)
      return url == second
    }

    XCTAssertEqual(result, second)
    XCTAssertEqual(inspected, [first.path, second.path])
  }
}
