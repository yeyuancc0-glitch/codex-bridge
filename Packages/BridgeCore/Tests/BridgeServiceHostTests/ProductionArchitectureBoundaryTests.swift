import Foundation
import XCTest

final class ProductionArchitectureBoundaryTests: XCTestCase {
  private static let productionTargets = [
    "BridgeACP",
    "BridgeAgentCore",
    "BridgeAntigravityCLI",
    "BridgeCodexRPC",
    "BridgeCodexService",
    "BridgeDirectCommand",
    "BridgeDeepSeekHarnessACP",
    "BridgeDomain",
    "BridgeFiles",
    "BridgeGit",
    "BridgeIPC",
    "BridgeLegacyImport",
    "BridgeMCP",
    "BridgeOpenCodeACP",
    "BridgeProcess",
    "BridgeProjects",
    "BridgeSecurity",
    "BridgeServiceApplication",
    "BridgeServiceAppShell",
    "BridgeServiceCore",
    "BridgeServiceHost",
    "BridgeSkills",
    "BridgeSupervisor",
    "BridgeTunnel",
  ]

  private static let legacyControlPlaneTargets: Set<String> = [
    "BridgeAppModel",
    "BridgeApplication",
    "BridgeAppShell",
    "BridgeCoordinator",
    "BridgePersistence",
    "BridgePipeline",
    "BridgePresentation",
    "BridgeReporting",
    "BridgeRepositories",
    "BridgeRuntime",
    "BridgeVerification",
  ]

  func testProductionTargetsDoNotImportLegacyControlPlane() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    for target in Self.productionTargets {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      let sourceFiles = try Self.swiftFiles(in: targetRoot)
      XCTAssertFalse(sourceFiles.isEmpty, "Missing production target sources: \(target)")
      for sourceFile in sourceFiles {
        let imports = try Self.internalImports(in: sourceFile)
        let forbidden = imports.intersection(Self.legacyControlPlaneTargets)
        XCTAssertTrue(
          forbidden.isEmpty,
          "\(target) imports legacy control-plane modules \(forbidden.sorted()) in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  func testXPCControllerDoesNotBypassApplicationRuntimeFacade() throws {
    let hostRoot = Self.packageRoot.appending(
      path: "Sources/BridgeServiceHost",
      directoryHint: .isDirectory
    )
    let forbidden = [
      "composition.coordinator",
      "composition.projects",
      "composition.settings",
      "composition.store",
      "composition.tasks",
    ]
    let controllerFiles = try Self.swiftFiles(in: hostRoot).filter {
      $0.lastPathComponent.hasPrefix("BridgeServiceXPCController")
    }
    XCTAssertFalse(controllerFiles.isEmpty)
    for sourceFile in controllerFiles {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      for access in forbidden {
        XCTAssertFalse(
          source.contains(access),
          "XPC controller bypasses the application runtime facade with \(access) in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  func testCodexExecutionTargetsDoNotImportDirectExecutionModules() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    let forbidden: Set<String> = ["BridgeDirectCommand", "BridgeProcess"]
    for target in ["BridgeCodexRPC", "BridgeCodexService"] {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      for sourceFile in try Self.swiftFiles(in: targetRoot) {
        let imports = try Self.internalImports(in: sourceFile)
        XCTAssertTrue(
          imports.isDisjoint(with: forbidden),
          "\(target) imports a Direct execution module in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  func testCodexAppServerUsesFoundationProcessWithoutBridgeSandboxWrapper() throws {
    let sourceFile = Self.packageRoot.appending(
      path: "Sources/BridgeCodexRPC/AppServerProcess.swift",
      directoryHint: .notDirectory
    )
    let source = try String(contentsOf: sourceFile, encoding: .utf8)
    XCTAssertTrue(source.contains("let process = Process()"))
    XCTAssertTrue(source.contains("try state.process.run()"))

    let forbidden = [
      "BridgeDirectCommand",
      "DirectCommandRunner",
      "ManagedStdioProcess",
      "sandbox-exec",
    ]
    for token in forbidden {
      XCTAssertFalse(
        source.contains(token),
        "Codex app-server launch must not use the Bridge Direct execution path: \(token)"
      )
    }
  }

  func testEmbeddedServiceResourcesAreStagedAndRequiredByReleaseBuilds() throws {
    let repositoryRoot = Self.packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let project = try String(
      contentsOf: repositoryRoot.appending(path: "CodexBridge.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    let stagingScript = try String(
      contentsOf: repositoryRoot.appending(path: "Scripts/stage-embedded-service-resources.sh"),
      encoding: .utf8
    )
    let releaseScript = try String(
      contentsOf: repositoryRoot.appending(path: "Scripts/build-release-candidate.sh"),
      encoding: .utf8
    )
    let bundleName = "BridgeCore_BridgeDeepSeekHarnessACP.bundle"

    XCTAssertTrue(project.contains("Stage Embedded Service Resources"))
    XCTAssertTrue(project.contains("Scripts/stage-embedded-service-resources.sh"))
    XCTAssertTrue(project.contains(bundleName))
    XCTAssertTrue(stagingScript.contains("BUILT_PRODUCTS_DIR"))
    XCTAssertTrue(stagingScript.contains("UNLOCALIZED_RESOURCES_FOLDER_PATH"))
    XCTAssertTrue(stagingScript.contains("Contents/Resources/cordis.yml"))
    XCTAssertTrue(
      releaseScript.contains("Archive did not contain the DeepSeek Harness resource bundle."))
  }

  private static var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func swiftFiles(in directory: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }
    return try enumerator.compactMap { value in
      guard let url = value as? URL, url.pathExtension == "swift" else { return nil }
      let values = try url.resourceValues(forKeys: Set(keys))
      return values.isRegularFile == true ? url : nil
    }
  }

  private static func internalImports(in sourceFile: URL) throws -> Set<String> {
    let source = try String(contentsOf: sourceFile, encoding: .utf8)
    return Set(
      source.split(separator: "\n").compactMap { line in
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "import" else { return nil }
        let module = parts[1].split(separator: ".", maxSplits: 1)[0]
        return module.hasPrefix("Bridge") ? String(module) : nil
      }
    )
  }
}
