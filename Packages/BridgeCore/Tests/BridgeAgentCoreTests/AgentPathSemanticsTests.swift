import XCTest

@testable import BridgeAgentCore

final class AgentPathSemanticsTests: XCTestCase {
  func testPosixAbsoluteAndPathListSemantics() {
    XCTAssertTrue(AgentPathSemantics.isAbsolute("/tmp/project", style: .posix))
    XCTAssertFalse(AgentPathSemantics.isAbsolute("tmp/project", style: .posix))
    XCTAssertEqual(
      AgentPathSemantics.splitPathList("/usr/bin:/bin", style: .posix),
      ["/usr/bin", "/bin"]
    )
    XCTAssertEqual(
      AgentPathSemantics.joinPathList(["/usr/bin", "/bin"], style: .posix),
      "/usr/bin:/bin"
    )
  }

  func testPosixContainmentIsBoundaryAware() {
    let root = "/Users/alice/project"
    XCTAssertTrue(
      AgentPathSemantics.isContained(
        "/Users/alice/project/Sources/App.swift",
        in: root,
        style: .posix
      )
    )
    XCTAssertEqual(
      AgentPathSemantics.relativePath(
        "/Users/alice/project/Sources/../App.swift",
        from: root,
        style: .posix
      ),
      "App.swift"
    )
    XCTAssertFalse(
      AgentPathSemantics.isContained(
        "/Users/alice/project-files/App.swift",
        in: root,
        style: .posix
      )
    )
  }

  func testWindowsAbsolutePathsAndRejectedNamespaces() {
    XCTAssertTrue(AgentPathSemantics.isAbsolute(#"C:\Users\Alice"#, style: .windows))
    XCTAssertTrue(AgentPathSemantics.isAbsolute(#"C:/Users/Alice"#, style: .windows))
    XCTAssertTrue(AgentPathSemantics.isAbsolute(#"/C:/Users/Alice"#, style: .windows))
    XCTAssertEqual(
      AgentPathSemantics.canonicalPath(#"/C:/Users/Alice/../Bin"#, style: .windows),
      #"C:\Users\Bin"#
    )
    XCTAssertTrue(AgentPathSemantics.isAbsolute(#"\\server\share\project"#, style: .windows))
    XCTAssertFalse(AgentPathSemantics.isAbsolute(#"C:\Users\Alice:stream"#, style: .windows))
    XCTAssertFalse(AgentPathSemantics.isAbsolute(#"C:Users\Alice"#, style: .windows))
    XCTAssertFalse(AgentPathSemantics.isAbsolute(#"\Users\Alice"#, style: .windows))

    for path in [
      #"\\?\C:\Users\Alice"#,
      #"\\.\PIPE\bridge"#,
      #"\??\C:\Users\Alice"#,
      #"\Device\HarddiskVolume1\Users\Alice"#,
    ] {
      XCTAssertFalse(AgentPathSemantics.isAbsolute(path, style: .windows), path)
    }
  }

  func testWindowsRelativeComponentsRejectTraversalWithEitherSeparator() {
    XCTAssertEqual(
      AgentPathSemantics.relativeComponents(#"Sources\Bridge\App.swift"#, style: .windows),
      ["Sources", "Bridge", "App.swift"]
    )
    for path in [
      #"../outside"#,
      #"Sources/../outside"#,
      #"Sources\..\outside"#,
      #"/absolute/path"#,
      #"C:\absolute\path"#,
      #"C:relative\path"#,
    ] {
      XCTAssertNil(AgentPathSemantics.relativeComponents(path, style: .windows), path)
    }
  }

  func testWindowsCanonicalContainmentIsCaseInsensitiveAndBoundaryAware() {
    let root = #"C:\Users\Alice\Project"#
    let candidate = #"c:/users/alice/project/Sources/App.swift"#
    XCTAssertEqual(
      AgentPathSemantics.canonicalPath(
        #"C:/Users/Alice/Project/./Sources/../App.swift"#, style: .windows),
      #"C:\Users\Alice\Project\App.swift"#
    )
    XCTAssertTrue(AgentPathSemantics.isContained(candidate, in: root, style: .windows))
    XCTAssertEqual(
      AgentPathSemantics.relativePath(candidate, from: root, style: .windows),
      #"Sources\App.swift"#
    )
    XCTAssertFalse(
      AgentPathSemantics.isContained(
        #"C:\Users\Alice\ProjectFiles\App.swift"#, in: root, style: .windows)
    )
  }

  func testWindowsUNCContainmentAndPathListSemantics() {
    let root = #"\\Server\Share\Project"#
    let candidate = #"\\server/share/project/Sources/App.swift"#
    XCTAssertTrue(AgentPathSemantics.isContained(candidate, in: root, style: .windows))
    XCTAssertEqual(
      AgentPathSemantics.relativePath(candidate, from: root, style: .windows),
      #"Sources\App.swift"#
    )
    XCTAssertEqual(
      AgentPathSemantics.canonicalPath(candidate, style: .windows),
      #"\\server\share\project\Sources\App.swift"#
    )
    XCTAssertEqual(
      AgentPathSemantics.splitPathList(#"C:\Tools;C:\Windows\System32"#, style: .windows),
      [#"C:\Tools"#, #"C:\Windows\System32"#]
    )
    XCTAssertEqual(
      AgentPathSemantics.joinPathList([#"C:\Tools"#, #"C:\Windows\System32"#], style: .windows),
      #"C:\Tools;C:\Windows\System32"#
    )
  }

  func testWindowsProviderEnvironmentUsesWindowsHomeAndPATHRules() throws {
    XCTAssertEqual(
      try AgentProviderEnvironment.homeDirectory(
        source: [
          "USERPROFILE": #"C:\Users\Alice"#,
          "HOMEDRIVE": "D:",
          "HOMEPATH": #"\Users\Fallback"#,
          "HOME": #"E:\wrong"#,
        ],
        field: "home",
        style: .windows
      ),
      #"C:\Users\Alice"#
    )
    XCTAssertEqual(
      try AgentProviderEnvironment.homeDirectory(
        source: [
          "HOMEDRIVE": "D:",
          "HOMEPATH": #"\Users\Alice"#,
        ],
        field: "home",
        style: .windows
      ),
      #"D:\Users\Alice"#
    )
    XCTAssertEqual(
      AgentProviderEnvironment.executableSearchPath(
        executablePath: #"C:\Tools\agent.exe"#,
        sourcePath: #"C:\Bin;C:\Tools;C:\bin"#,
        style: .windows
      ),
      #"C:\Tools;C:\Bin"#
    )
    XCTAssertEqual(
      AgentProviderEnvironment.executableSearchPath(
        executablePath: #"C:\Tools\agent.exe"#,
        source: ["Path": #"C:\Bin;C:\Tools"#],
        style: .windows
      ),
      #"C:\Tools;C:\Bin"#
    )
  }
}
