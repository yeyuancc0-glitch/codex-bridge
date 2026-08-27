import BridgeDomain
import BridgeMCP
import BridgePipeline
import XCTest

@testable import BridgeAppShell
@testable import BridgeGit

final class DesktopTaskArtifactQueriesTests: XCTestCase {
  func testPersistentGitEvidenceDrivesBoundedSummaryAndDiffPages() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try TaskEvidenceScope(
      taskID: TaskID(rawValue: "task-artifacts"),
      projectID: ProjectID(rawValue: "project-artifacts"),
      threadID: ThreadID(rawValue: "thread-artifacts"),
      turnID: TurnID(rawValue: "turn-artifacts"),
      generation: 1,
      eventSequence: 4
    )
    _ = try await store.begin(scope)
    let baseline = GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 100),
      status: status(entries: [change(path: "existing.txt", workTreeStatus: "M")]),
      changeAttribution: .mixedWithPreexistingChanges
    )
    let final = GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 200),
      status: status(
        entries: [
          change(path: "Sources/A.swift", workTreeStatus: "M"),
          change(path: "Sources/B.swift", workTreeStatus: "D"),
        ]
      ),
      diffStat: "2 files changed",
      changedFiles: ["Sources/A.swift", "Sources/B.swift"],
      untrackedFiles: [],
      patch: nil,
      changeAttribution: .mixedWithPreexistingChanges
    )
    _ = try await store.store(scope: scope, kind: .gitBaseline, payload: baseline)
    _ = try await store.store(scope: scope, kind: .gitFinal, payload: final)
    let queries = DesktopTaskArtifactQueries(
      artifacts: store,
      patches: GitPatchStore()
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))

    let summary = try await queries.summary(
      taskID: scope.taskID.rawValue,
      deadline: deadline
    )
    let first = try await queries.diff(
      taskID: scope.taskID.rawValue,
      cursor: nil,
      limit: 1,
      includePatch: false,
      deadline: deadline
    )
    let second = try await queries.diff(
      taskID: scope.taskID.rawValue,
      cursor: first.nextCursor,
      limit: 1,
      includePatch: false,
      deadline: deadline
    )

    XCTAssertEqual(summary.changedFileCount, 2)
    XCTAssertEqual(first.files.map(\.relativePath), ["Sources/A.swift"])
    XCTAssertEqual(first.files.map(\.status), ["modified"])
    XCTAssertEqual(first.nextCursor, "files:1")
    XCTAssertEqual(second.files.map(\.relativePath), ["Sources/B.swift"])
    XCTAssertEqual(second.files.map(\.status), ["deleted"])
    XCTAssertNil(second.nextCursor)
    XCTAssertTrue(first.baselineWasDirty)
  }

  func testPatchPagesFitMCPResultLimitAndPreserveMultibyteUTF8() async throws {
    try await assertPatchCanBeReassembled(
      String(repeating: "+let message = \"测试\"\n", count: 2_500),
      taskSuffix: "multibyte"
    )
  }

  func testPatchPagesFitProductionWrapperWithWorstCaseJSONEscaping() async throws {
    try await assertPatchCanBeReassembled(
      String(repeating: "\u{1}", count: 30_000),
      taskSuffix: "control"
    )
  }

  func testPatchPagesSanitizeAndBoundLargeDiffStat() async throws {
    try await assertPatchCanBeReassembled(
      "patch body",
      taskSuffix: "large-diff-stat",
      diffStat: "password=actual-secret-value\n" + String(repeating: "d", count: 160 * 1_024)
    )
  }

  func testFilePageRedactsSensitiveNamesAndAdaptsWholeResponseBudget() async throws {
    let store = try PipelineArtifactStore.inMemory()
    let scope = try TaskEvidenceScope(
      taskID: TaskID(rawValue: "task-file-budget"),
      projectID: ProjectID(rawValue: "project-file-budget"),
      threadID: ThreadID(rawValue: "thread-file-budget"),
      turnID: TurnID(rawValue: "turn-file-budget"),
      generation: 1,
      eventSequence: 4
    )
    _ = try await store.begin(scope)
    let sensitive = "password=actual-secret-value"
    let longPaths = (0..<100).map { index in
      "Sources/\(String(repeating: "a", count: 900))\(index).swift"
    }
    let paths =
      [
        sensitive,
        "Sources/back\\slash.swift",
        "Sources/control\u{1}name.swift",
      ] + longPaths
    let entries = paths.map { change(path: $0, workTreeStatus: "?") }
    let baseline = GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 100),
      status: status(entries: []),
      changeAttribution: .attributableFromCleanBaseline
    )
    let final = GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 200),
      status: status(entries: entries),
      diffStat: String(repeating: "d", count: 160 * 1_024),
      changedFiles: paths,
      untrackedFiles: paths,
      patch: nil,
      changeAttribution: .attributableFromCleanBaseline
    )
    _ = try await store.store(scope: scope, kind: .gitBaseline, payload: baseline)
    _ = try await store.store(scope: scope, kind: .gitFinal, payload: final)
    let queries = DesktopTaskArtifactQueries(artifacts: store, patches: GitPatchStore())
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    var cursor: String?
    var files: [MCPTaskDiffFile] = []

    repeat {
      let page = try await queries.diff(
        taskID: scope.taskID.rawValue,
        cursor: cursor,
        limit: 100,
        includePatch: false,
        deadline: deadline
      )
      _ = try MCPToolResultEncoder().encodeTaskDiffPage(page)
      XCTAssertLessThanOrEqual(page.diffStat.utf8.count, 8 * 1_024)
      files += page.files
      cursor = page.nextCursor
    } while cursor != nil

    XCTAssertEqual(files.count, paths.count)
    XCTAssertEqual(files.first?.relativePath, "[redacted-sensitive-path-0]")
    XCTAssertEqual(files[1].relativePath, "[redacted-sensitive-path-1]")
    XCTAssertEqual(files[2].relativePath, "[redacted-sensitive-path-2]")
    XCTAssertFalse(files.contains { $0.relativePath.contains("actual-secret-value") })
  }

  private func assertPatchCanBeReassembled(
    _ original: String,
    taskSuffix: String,
    diffStat: String = "1 file changed"
  ) async throws {
    let store = try PipelineArtifactStore.inMemory()
    let patches = GitPatchStore()
    let scope = try TaskEvidenceScope(
      taskID: TaskID(rawValue: "task-patch-pages-\(taskSuffix)"),
      projectID: ProjectID(rawValue: "project-patch-pages-\(taskSuffix)"),
      threadID: ThreadID(rawValue: "thread-patch-pages-\(taskSuffix)"),
      turnID: TurnID(rawValue: "turn-patch-pages-\(taskSuffix)"),
      generation: 1,
      eventSequence: 4
    )
    _ = try await store.begin(scope)
    let baseline = GitBaselineEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 100),
      status: status(entries: []),
      changeAttribution: .attributableFromCleanBaseline
    )
    let handle = try await patches.store(Data(original.utf8), isTruncated: false)
    let final = GitFinalEvidence(
      projectIdentifier: scope.projectID.rawValue,
      canonicalRootPath: "/registered/root",
      capturedAt: Date(timeIntervalSince1970: 200),
      status: status(entries: []),
      diffStat: diffStat,
      changedFiles: [],
      untrackedFiles: [],
      patch: handle,
      changeAttribution: .attributableFromCleanBaseline
    )
    _ = try await store.store(scope: scope, kind: .gitBaseline, payload: baseline)
    _ = try await store.store(scope: scope, kind: .gitFinal, payload: final)
    let queries = DesktopTaskArtifactQueries(artifacts: store, patches: patches)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var cursor: String? = "patch:0"
    var reconstructed = ""

    while let current = cursor {
      let page = try await queries.diff(
        taskID: scope.taskID.rawValue,
        cursor: current,
        limit: 1,
        includePatch: true,
        deadline: deadline
      )
      _ = try MCPToolResultEncoder().encodeTaskDiffPage(page)
      XCTAssertLessThanOrEqual(page.diffStat.utf8.count, 8 * 1_024)
      XCTAssertFalse(page.diffStat.contains("actual-secret-value"))
      reconstructed += try XCTUnwrap(page.patch)
      cursor = page.nextCursor
    }

    XCTAssertEqual(reconstructed, original)
  }

  private func status(entries: [GitFileChange]) -> GitStatusEvidence {
    GitStatusEvidence(
      repositoryClassification: .gitWorkingTree,
      branch: "main",
      headCommit: String(repeating: "a", count: 40),
      detachedHead: false,
      entries: entries,
      porcelainV2: Data()
    )
  }

  private func change(path: String, workTreeStatus: String) -> GitFileChange {
    GitFileChange(
      kind: .ordinary,
      path: path,
      workTreeStatus: workTreeStatus
    )
  }
}
