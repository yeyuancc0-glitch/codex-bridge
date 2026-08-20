import BridgeSkills
import Foundation
import XCTest

final class SkillScannerTests: XCTestCase {
  func testDiscoversInstalledSkillWhoseDirectoryAndDeclaredNameContainSpaces() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/code review")
    try makeSkill(at: skill, description: "Two-axis review")

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)

    XCTAssertEqual(manifests.map(\.name), ["code review"])
    XCTAssertEqual(manifests.first?.description, "Two-axis review")
    let document = try await scanner.readSkillDocument(XCTUnwrap(manifests.first))
    XCTAssertTrue(document.content.contains("name: code review"))
  }

  func testProjectSkillOverridesGlobalAndReadsReference() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectSkills = root.appendingPathComponent("project/skills").appendingPathComponent(
      "review")
    let globalSkills = root.appendingPathComponent("global").appendingPathComponent("review")
    try makeSkill(at: projectSkills, description: "project", reference: "project reference")
    try makeSkill(at: globalSkills, description: "global")

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("global")])
    let manifests = try await scanner.scanSkills(
      for: root.appendingPathComponent("project")
    )
    XCTAssertEqual(manifests.map(\.name), ["review"])
    XCTAssertEqual(manifests.first?.scope, .project)
    XCTAssertEqual(manifests.first?.description, "project")

    let document = try await scanner.readSkillDocument(
      manifests[0], subpath: "references/guide.md"
    )
    XCTAssertEqual(document.content, "project reference")
  }

  func testFrontmatterParsesBlockScalarSequencesAndNestedTriggers() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/agent-reach")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    let fixture = Bundle.module.url(
      forResource: "agent-reach-SKILL", withExtension: "md", subdirectory: "Fixtures")
    let data = try Data(contentsOf: XCTUnwrap(fixture))
    try data.write(to: skill.appendingPathComponent("SKILL.md"))

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)
    XCTAssertEqual(manifest.name, "agent-reach")
    XCTAssertTrue(manifest.description.contains("MUST USE when user wants"))
    XCTAssertTrue(manifest.description.contains("Also MUST USE"))
    XCTAssertTrue(manifest.description.contains("15 platforms"))
    XCTAssertTrue(manifest.description.contains("NOT for"))
    XCTAssertTrue(manifest.triggers.contains { $0.hasPrefix("research: 调研/全网调研/帮我调研") })
    XCTAssertTrue(manifest.triggers.contains { $0.hasPrefix("search: 搜/查/找/search") })
    XCTAssertTrue(manifest.triggers.contains("social:"))
    XCTAssertTrue(manifest.triggers.contains { $0.hasPrefix("Twitter: twitter/推特/x.com") })
  }

  func testFrontmatterParsesInlineSequenceAndQuotedValues() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/code-review")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    let frontmatter = """
      ---
      name: code-review
      description: "Rigorous code review."
      triggers: [review, audit, /codereview]
      ---
      # Body
      """
    try Data(frontmatter.utf8).write(to: skill.appendingPathComponent("SKILL.md"))

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)
    XCTAssertEqual(manifest.description, "Rigorous code review.")
    XCTAssertEqual(manifest.triggers, ["review", "audit", "/codereview"])
  }

  func testActionsDiscoveredOnlyWhenDocumentedAndExcludesInternals() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/impeccable")
    let scripts = skill.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(
      at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: scripts.appendingPathComponent("detector/shared"), withIntermediateDirectories: true)
    let document = """
      ---
      name: impeccable
      description: Design skill.
      ---
      Run scripts/context.mjs, scripts/palette.mjs, and scripts/setup.sh.
      """
    try Data(document.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    // Top-level executable entrypoints.
    try Data("#!/usr/bin/env node\nconsole.log('context');\n".utf8)
      .write(to: scripts.appendingPathComponent("context.mjs"))
    try Data("print('palette')".utf8)
      .write(to: scripts.appendingPathComponent("palette.mjs"))
    try Data("#!/bin/sh\necho hi\n".utf8)
      .write(to: scripts.appendingPathComponent("setup.sh"))
    // Non-runnable / internal files that must NOT be exposed as actions.
    try Data("{}".utf8).write(to: scripts.appendingPathComponent("command-metadata.json"))
    try Data("export default {};\n".utf8)
      .write(to: scripts.appendingPathComponent("lib/shared.mjs"))
    try Data("injected\n".utf8)
      .write(to: scripts.appendingPathComponent("detector/shared/common.mjs"))
    try Data("(function () {})();\n".utf8)
      .write(to: scripts.appendingPathComponent("modern-screenshot.umd.js"))
    try Data("#!/usr/bin/env node\nconsole.log('internal');\n".utf8)
      .write(to: scripts.appendingPathComponent("live-server.mjs"))

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)
    let names = manifest.actions.map(\.name).sorted()
    XCTAssertEqual(names, ["context", "palette", "setup"])
    XCTAssertFalse(names.contains("command-metadata"))
    XCTAssertFalse(names.contains("shared"))
    XCTAssertFalse(names.contains("common"))
    XCTAssertFalse(names.contains("modern-screenshot.umd"))
    XCTAssertFalse(names.contains("live-server"))
    XCTAssertTrue(manifest.actions.allSatisfy { $0.interpreter != nil })
    XCTAssertTrue(manifest.actions.allSatisfy { $0.networkRequirement == .unspecified })
  }

  func testExplicitActionsMetadataOverridesDiscovery() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/demo")
    let scripts = skill.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let frontmatter = """
      ---
      name: demo
      description: Demo.
      actions:
        - name: generate
          script: scripts/gen.py
          interpreter: python3
          network_requirement: required
          description: Generate files
        - name: tidy
          path: scripts/tidy.py
      ---
      """
    try Data(frontmatter.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    try Data("print('gen')\n".utf8).write(to: scripts.appendingPathComponent("gen.py"))
    try Data("print('tidy')\n".utf8).write(to: scripts.appendingPathComponent("tidy.py"))

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)
    let names = manifest.actions.map(\.name)
    XCTAssertEqual(names, ["generate", "tidy"])
    let generate = try XCTUnwrap(manifest.actions.first { $0.name == "generate" })
    XCTAssertEqual(generate.scriptPath, "scripts/gen.py")
    XCTAssertEqual(generate.interpreter, "python3")
    XCTAssertTrue(generate.requiresNetwork)
    XCTAssertEqual(generate.networkRequirement, .required)
    XCTAssertEqual(generate.description, "Generate files")
    let tidy = try XCTUnwrap(manifest.actions.first { $0.name == "tidy" })
    XCTAssertEqual(tidy.scriptPath, "scripts/tidy.py")
    XCTAssertEqual(tidy.networkRequirement, .unspecified)
  }

  func testResolveActionUsesInterpreterOrShebang() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/demo")
    let scripts = skill.appendingPathComponent("scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    let document = """
      ---
      name: demo
      description: Demo.
      ---
      Use scripts/run.mjs and scripts/plain.py.
      """
    try Data(document.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    try Data("#!/usr/bin/env node\nconsole.log('hi');\n".utf8)
      .write(to: scripts.appendingPathComponent("run.mjs"))
    try Data("print('hi')".utf8).write(to: scripts.appendingPathComponent("plain.py"))

    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)

    let run = try await scanner.resolveAction("run", in: manifest)
    XCTAssertTrue(
      run.interpreter.contains("node"), "expected node interpreter, got \(run.interpreter)")
    XCTAssertTrue(run.resolvedScriptPath.hasSuffix("scripts/run.mjs"))

    let plain = try await scanner.resolveAction("plain", in: manifest)
    XCTAssertTrue(
      plain.interpreter.contains("python3"), "expected python3, got \(plain.interpreter)")
    XCTAssertTrue(plain.resolvedScriptPath.hasSuffix("scripts/plain.py"))

    do {
      _ = try await scanner.resolveAction("missing", in: manifest)
      XCTFail("Expected actionNotFound")
    } catch let error as SkillError {
      XCTAssertEqual(error, .actionNotFound)
    }
  }

  func testSkillDocumentsRejectEscapeSensitiveFileAndSymlink() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let skill = root.appendingPathComponent("skills/demo")
    try makeSkill(at: skill, description: "demo")
    try Data("secret".utf8).write(to: skill.appendingPathComponent(".env.local"))
    try Data("outside".utf8).write(to: root.appendingPathComponent("outside.md"))
    try FileManager.default.createSymbolicLink(
      at: skill.appendingPathComponent("outside.md"),
      withDestinationURL: root.appendingPathComponent("outside.md")
    )
    let scanner = SkillScanner(globalRoots: [root.appendingPathComponent("skills")])
    let manifests = try await scanner.scanSkills(for: nil)
    let manifest = try XCTUnwrap(manifests.first)

    do {
      _ = try await scanner.readSkillDocument(manifest, subpath: "../outside.md")
      XCTFail("Expected traversal to be rejected")
    } catch let error as SkillError {
      XCTAssertEqual(error, .pathEscapeDetected)
    }
    do {
      _ = try await scanner.readSkillDocument(manifest, subpath: ".env.local")
      XCTFail("Expected sensitive file to be rejected")
    } catch let error as SkillError {
      XCTAssertEqual(error, .sensitivePath)
    }
    do {
      _ = try await scanner.readSkillDocument(manifest, subpath: "outside.md")
      XCTFail("Expected symlink escape to be rejected")
    } catch let error as SkillError {
      XCTAssertEqual(error, .pathEscapeDetected)
    }
  }

  private func makeSkill(at directory: URL, description: String, reference: String? = nil) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text =
      "---\nname: \(directory.lastPathComponent)\ndescription: \(description)\ntriggers: [review, audit]\n---\n# Skill\n"
    try Data(text.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
    if let reference {
      let references = directory.appendingPathComponent("references")
      try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
      try Data(reference.utf8).write(to: references.appendingPathComponent("guide.md"))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
