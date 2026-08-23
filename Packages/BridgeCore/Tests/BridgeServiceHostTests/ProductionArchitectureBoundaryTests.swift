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
    "BridgeIPCMacOS",
    "BridgeIPCWindows",
    "BridgeLegacyImport",
    "BridgeMCP",
    "BridgePlatform",
    "BridgePlatformMacOS",
    "BridgeProcessRuntime",
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

  /// Targets that must stay compilable on the Windows host. Extending this
  /// list requires proving the target builds on native Windows runners.
  private static let windowsClosureTargets = [
    "BridgeCodexRPC",
    "BridgeDirectCommand",
    "BridgeDomain",
    "BridgeFiles",
    "BridgeIPC",
    "BridgeIPCWindows",
    "BridgeMCP",
    "BridgePlatform",
    "BridgePlatformWindows",
    "BridgeProcessRuntime",
    "BridgeProjects",
    "BridgeSecurity",
    "BridgeServiceCore",
    "BridgeSkills",
    "BridgeTunnel",
  ]

  private static let darwinOnlyModules: Set<String> = [
    "AppKit",
    "CoreServices",
    "CryptoKit",
    "Darwin",
    "IOKit",
    "OSLog",
    "Security",
    "ServiceManagement",
    "UIKit",
    "WebKit",
    "os",
  ]

  private static let windowsOnlyModules: Set<String> = [
    "UWP",
    "WinSDK",
    "WinUI",
  ]

  /// Targets whose source files differ per host under one module name. Every
  /// platform-coupled file inside them must be wrapped in a matching
  /// canImport gate.
  private static let splitHostTargets: Set<String> = [
    "BridgeCodexRPC",
    "BridgeDirectCommand",
    "BridgeFiles",
    "BridgeProcessRuntime",
    "BridgeSecurity",
    "BridgeServiceCore",
    "BridgeTunnel",
  ]

  func testProductionTargetsDoNotImportLegacyControlPlane() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    for target in Self.productionTargets {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      let sourceFiles = try Self.swiftFiles(in: targetRoot)
      XCTAssertFalse(sourceFiles.isEmpty, "Missing production target sources: \(target)")
      for sourceFile in sourceFiles {
        let imports = try Self.importedModules(in: sourceFile)
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

  func testWindowsClosureTargetsStayPlatformNeutral() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    for target in Self.windowsClosureTargets {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      let sourceFiles = try Self.swiftFiles(in: targetRoot)
      XCTAssertFalse(sourceFiles.isEmpty, "Missing Windows closure target sources: \(target)")
      if Self.splitHostTargets.contains(target) { continue }
      for sourceFile in sourceFiles {
        let imports = try Self.importedModules(in: sourceFile)
        let darwin = imports.intersection(Self.darwinOnlyModules)
        XCTAssertTrue(
          darwin.isEmpty,
          "Windows closure target \(target) imports Darwin-only modules \(darwin.sorted()) in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  func testMacOSOnlyTargetsDoNotImportWindowsModules() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    let macOSTargets = Set(Self.productionTargets).union(Self.legacyControlPlaneTargets)
      .subtracting(Self.windowsClosureTargets)
      .subtracting(Self.splitHostTargets)
    for target in macOSTargets.sorted() {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: targetRoot.path) else { continue }
      for sourceFile in try Self.swiftFiles(in: targetRoot) {
        let imports = try Self.importedModules(in: sourceFile)
        let windows = imports.intersection(Self.windowsOnlyModules)
        XCTAssertTrue(
          windows.isEmpty,
          "macOS target \(target) imports Windows-only modules \(windows.sorted()) in \(sourceFile.lastPathComponent)"
        )
      }
    }
  }

  func testSplitHostTargetsGatePlatformImports() throws {
    let sourcesRoot = Self.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    for target in Self.splitHostTargets {
      let targetRoot = sourcesRoot.appending(path: target, directoryHint: .isDirectory)
      for sourceFile in try Self.swiftFiles(in: targetRoot) {
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        if source.contains("import WinSDK") {
          XCTAssertTrue(
            source.contains("#if canImport(WinSDK)"),
            "\(sourceFile.lastPathComponent) must wrap its WinSDK usage in canImport(WinSDK)"
          )
        }
        if source.contains("import Darwin") {
          XCTAssertTrue(
            source.contains("#if canImport(Darwin)")
              || source.contains("#if !canImport(WinSDK)")
              || !source.contains("canImport(WinSDK)"),
            "\(sourceFile.lastPathComponent) mixes Darwin with a WinSDK gate"
          )
        }
      }
    }
  }

  func testBridgeIPCStaysTransportFree() throws {
    let ipcRoot = Self.packageRoot.appending(
      path: "Sources/BridgeIPC",
      directoryHint: .isDirectory
    )
    let forbiddenMarkers = ["NSXPCConnection", "NSXPCListener", "\\.pipe\\", "NamedPipe"]
    for sourceFile in try Self.swiftFiles(in: ipcRoot) {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      for marker in forbiddenMarkers {
        XCTAssertFalse(
          source.range(of: marker, options: .regularExpression) != nil,
          "BridgeIPC must stay transport-free but references \(marker) in \(sourceFile.lastPathComponent)"
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

  private static func importedModules(in sourceFile: URL) throws -> Set<String> {
    let source = try String(contentsOf: sourceFile, encoding: .utf8)
    return Set(
      source.split(separator: "\n").compactMap { line in
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "import" else { return nil }
        let module = parts[1].split(separator: ".", maxSplits: 1)[0]
        return String(module)
      }
    )
  }
}
