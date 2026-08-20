import Foundation
import XCTest

final class ProductionArchitectureBoundaryTests: XCTestCase {
  private static let productionTargets = [
    "BridgeCodexRPC",
    "BridgeCodexService",
    "BridgeDirectCommand",
    "BridgeDomain",
    "BridgeFiles",
    "BridgeGit",
    "BridgeIPC",
    "BridgeLegacyImport",
    "BridgeMCP",
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
