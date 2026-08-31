#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeAgentCore

  final class AgentExecutableResolverTests: XCTestCase {
    func testResolvesNativeExecutableFromCaseInsensitivePathAndPATHEXT() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bridge-executable-resolver-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let executable = root.appendingPathComponent("tool.exe")
      XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))

      let resolver = AgentExecutableResolver(
        environment: ["pAtH": root.path, "PaThExT": ".CMD;.EXE"],
        preferredExtensions: [".EXE"]
      )
      XCTAssertEqual(
        resolver.resolve("tool")?.lowercased(),
        executable.path.lowercased()
      )
      XCTAssertNil(resolver.resolve("tool.cmd"))
    }

    func testSafeSearchOmitsUserDirectories() {
      let resolver = AgentExecutableResolver(
        environment: [
          "USERPROFILE": #"C:\Users\Alice"#,
          "LOCALAPPDATA": #"C:\Users\Alice\AppData\Local"#,
          "ProgramFiles": #"C:\Program Files"#,
        ],
        includeEnvironmentPath: false,
        includeUserDirectories: false
      )
      let directories = resolver.searchDirectories().map { $0.lowercased() }
      XCTAssertFalse(directories.contains(#"c:\users\alice\.local\bin"#))
      XCTAssertFalse(directories.contains(#"c:\users\alice\appdata\local\programs\nodejs"#))
      XCTAssertTrue(directories.contains(#"c:\program files\git\cmd"#))
    }
  }
#endif
