#if os(Windows)
  import Foundation
  import XCTest

  @testable import BridgeCodexRPC

  final class CodexExecutableResolverTests: XCTestCase {
    func testPathCmdResolvesToNativeExecutableOnly() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let npmDirectory = fixture.path("AppData", "Roaming", "npm")
      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let native = try fixture.makeNativeExecutable(
        packageRoot: packageRoot, architecture: .current)
      try fixture.write("@echo off\r\n", to: fixture.path("AppData", "Roaming", "npm", "codex.cmd"))

      let resolver = CodexExecutableResolver(
        environment: fixture.environment(path: npmDirectory),
        architecture: .current
      )
      let resolved = try XCTUnwrap(resolver.resolve())

      XCTAssertEqual(CodexWindowsPath.normalize(resolved), CodexWindowsPath.normalize(native))
      XCTAssertTrue(resolved.lowercased().hasSuffix(".exe"))
      XCTAssertFalse(resolved.lowercased().hasSuffix(".cmd"))
    }

    func testExplicitCmdResolvesOnlyThroughItsKnownNativePackage() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let npmDirectory = fixture.path("AppData", "Roaming", "npm")
      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let native = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .amd64)
      let shim = fixture.path("AppData", "Roaming", "npm", "codex.cmd")
      try fixture.write("@echo off\r\n", to: shim)

      let resolver = CodexExecutableResolver(
        environment: fixture.environment(path: npmDirectory),
        architecture: .amd64
      )
      let resolved = try XCTUnwrap(resolver.resolve(explicitPath: shim))

      XCTAssertEqual(CodexWindowsPath.normalize(resolved), CodexWindowsPath.normalize(native))
      XCTAssertEqual(
        resolver.resolve(explicitPath: fixture.path("tools", "arbitrary.cmd")),
        nil
      )
    }

    func testCustomAbsolutePathExecutableIsDiscovered() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let customDirectory = fixture.path("D", "Tools", "codex")
      let native = try fixture.makeDirectExecutable(
        directory: customDirectory,
        architecture: .current
      )
      let environment = fixture.environment(path: customDirectory)
      let resolver = CodexExecutableResolver(environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testPathRejectsNonPEExecutable() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let directory = fixture.path("Tools", "Codex")
      try fixture.write(
        "not a portable executable",
        to: fixture.path("Tools", "Codex", "codex.exe")
      )
      let resolver = CodexExecutableResolver(
        environment: fixture.environment(path: directory),
        architecture: .current
      )

      XCTAssertNil(resolver.resolve())
    }

    func testPathRejectsExecutableForAnotherArchitecture() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let directory = fixture.path("Tools", "Codex")
      let otherArchitecture: CodexWindowsArchitecture
      switch CodexWindowsArchitecture.current {
      case .amd64:
        otherArchitecture = .arm64
      case .arm64:
        otherArchitecture = .amd64
      }
      _ = try fixture.makeDirectExecutable(
        directory: directory,
        architecture: otherArchitecture
      )
      let resolver = CodexExecutableResolver(
        environment: fixture.environment(path: directory),
        architecture: .current
      )

      XCTAssertNil(resolver.resolve())
    }

    func testResolverSelectsCurrentArchitectureNativePackage() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let packageRoot = fixture.path(
        "AppData",
        "Roaming",
        "npm",
        "node_modules",
        "@openai",
        "codex"
      )
      let amd64 = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .amd64)
      let arm64 = try fixture.makeNativeExecutable(packageRoot: packageRoot, architecture: .arm64)
      let environment = fixture.environment(path: fixture.path("AppData", "Roaming", "npm"))

      let amd64Resolved = try XCTUnwrap(
        CodexExecutableResolver(environment: environment, architecture: .amd64).resolve()
      )
      let arm64Resolved = try XCTUnwrap(
        CodexExecutableResolver(environment: environment, architecture: .arm64).resolve()
      )

      XCTAssertEqual(CodexWindowsPath.normalize(amd64Resolved), CodexWindowsPath.normalize(amd64))
      XCTAssertEqual(CodexWindowsPath.normalize(arm64Resolved), CodexWindowsPath.normalize(arm64))
    }

    func testResolverFindsLocalAppDataInstallation() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("AppData", "Local", "Programs", "OpenAI", "Codex", "bin"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("Project", "bin"))
      let resolver = CodexExecutableResolver(environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testResolverFindsUserProfileStandaloneInstallation() throws {
      let fixture = try Fixture()
      defer { fixture.remove() }

      let native = try fixture.makeDirectExecutable(
        directory: fixture.path("User", ".codex", "packages", "standalone", "current", "bin"),
        architecture: .current
      )
      let environment = fixture.environment(path: fixture.path("Project", "bin"))
      let resolver = CodexExecutableResolver(environment: environment, architecture: .current)

      XCTAssertEqual(
        CodexWindowsPath.normalize(try XCTUnwrap(resolver.resolve())),
        CodexWindowsPath.normalize(native)
      )
    }

    func testWindowsCodexConfigurationNeverUsesPosixFallback() {
      let configuration = AppServerConfiguration.codex()
      XCTAssertNotEqual(configuration.executableURL.path, "/usr/bin/env")
    }
  }

  private final class Fixture {
    let root: String

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-resolver-" + UUID().uuidString, isDirectory: true)
        .path
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(_ components: String...) -> String {
      var url = URL(fileURLWithPath: root, isDirectory: true)
      for (index, component) in components.enumerated() {
        url.appendPathComponent(component, isDirectory: index < components.count - 1)
      }
      return url.path
    }

    func environment(path: String) -> [String: String] {
      [
        "PATH": path,
        "APPDATA": self.path("AppData", "Roaming"),
        "LOCALAPPDATA": self.path("AppData", "Local"),
        "USERPROFILE": self.path("User"),
        "ProgramFiles": self.path("Program Files"),
        "ProgramW6432": self.path("Program Files"),
        "ProgramFiles(x86)": self.path("Program Files (x86)"),
      ]
    }

    func makeDirectExecutable(
      directory: String,
      architecture: CodexWindowsArchitecture
    ) throws -> String {
      let path = URL(fileURLWithPath: directory, isDirectory: true)
        .appendingPathComponent("codex.exe")
        .path
      try write(Self.peImage(for: architecture), to: path)
      return path
    }

    func makeNativeExecutable(
      packageRoot: String,
      architecture: CodexWindowsArchitecture
    ) throws -> String {
      let path = URL(fileURLWithPath: packageRoot, isDirectory: true)
        .appendingPathComponent("node_modules", isDirectory: true)
        .appendingPathComponent("@openai", isDirectory: true)
        .appendingPathComponent(architecture.nativePackageName, isDirectory: true)
        .appendingPathComponent("vendor", isDirectory: true)
        .appendingPathComponent(architecture.vendorTriple, isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("codex.exe")
        .path
      try write(Self.peImage(for: architecture), to: path)
      return path
    }

    func write(_ value: String, to path: String) throws {
      try write(Data(value.utf8), to: path)
    }

    func write(_ data: Data, to path: String) throws {
      try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
        withIntermediateDirectories: true
      )
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func remove() {
      try? FileManager.default.removeItem(atPath: root)
    }

    private static func peImage(for architecture: CodexWindowsArchitecture) -> Data {
      let machine: UInt16
      switch architecture {
      case .amd64:
        machine = 0x8664
      case .arm64:
        machine = 0xAA64
      }
      var bytes = [UInt8](repeating: 0, count: 512)
      bytes[0] = 0x4D
      bytes[1] = 0x5A
      bytes[0x3C] = 0x80
      bytes[0x80] = 0x50
      bytes[0x81] = 0x45
      bytes[0x84] = UInt8(machine & 0xFF)
      bytes[0x85] = UInt8(machine >> 8)
      bytes[0x96] = 0x02
      return Data(bytes)
    }
  }
#endif
