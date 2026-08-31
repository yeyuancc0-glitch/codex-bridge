#if os(Windows)
  import BridgeAgentCore
  import BridgeServiceCore
  import Foundation
  import XCTest

  final class ServiceAgentWindowsPathTests: XCTestCase {
    func testRegistrationAcceptsDriveAndUNCPaths() throws {
      let drive = try ServiceAgentRegistrationRequest(
        providerID: .openCode,
        displayName: "OpenCode",
        executablePath: #"C:\Tools\opencode.exe"#,
        trustProfile: .managed,
        projectRoot: #"C:\Work\Project"#,
        configurationPath: #"C:\Work\Project\config.json"#
      )
      XCTAssertEqual(drive.executablePath, #"C:\Tools\opencode.exe"#)

      let unc = try ServiceAgentRegistrationRequest(
        providerID: .antigravity,
        displayName: "Antigravity",
        executablePath: #"\\server\share\antigravity.exe"#,
        trustProfile: .userTrusted,
        projectRoot: #"\\server\share\Project"#,
        configurationPath: #"\\server\share\Project\config.json"#
      )
      XCTAssertEqual(unc.projectRoot, #"\\server\share\Project"#)
    }

    func testArtifactAndInstallationRecordAcceptWindowsPaths() throws {
      let path = #"D:\Agents\deepseek\node.exe"#
      let artifact = try ServiceAgentInstallationArtifactRequest(
        role: .nodeInterpreter,
        path: path
      )
      XCTAssertEqual(artifact.path, path)

      let identity = try ServiceAgentExecutableIdentity(
        canonicalPath: path,
        device: 1,
        inode: 2,
        fileSize: 3,
        modificationTimeNanoseconds: 4,
        sha256: String(repeating: "0", count: 64)
      )
      let record = try ServiceAgentInstallationRecord(
        id: AgentInstallationID(rawValue: "windows-path"),
        providerID: .deepSeekHarness,
        displayName: "DeepSeek Harness",
        executablePath: path,
        executableIdentity: identity,
        version: nil,
        protocolRevision: nil,
        adapterRevision: 1,
        trustProfile: .managed,
        securityProfileID: nil,
        isEnabled: false,
        availability: .unavailable,
        capabilities: .empty,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
      )
      XCTAssertEqual(record.executablePath, path)
    }

    func testRegistrationRejectsRelativePaths() {
      XCTAssertThrowsError(
        try ServiceAgentRegistrationRequest(
          providerID: .openCode,
          displayName: "OpenCode",
          executablePath: "opencode.exe",
          trustProfile: .managed,
          projectRoot: "project",
          configurationPath: "config.json"
        )
      )
      XCTAssertThrowsError(
        try ServiceAgentInstallationArtifactRequest(
          role: .nodeInterpreter,
          path: "node.exe"
        )
      )
    }
  }
#endif
