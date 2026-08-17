import BridgeServiceCore
import Foundation

public actor LegacyConfigurationImporter {
  public static let markerKey = "migration.legacy-v1.completed"

  private let legacyRootURL: URL
  private let store: SimpleServiceStore
  private let now: @Sendable () -> Date

  public init(
    legacyRootURL: URL,
    store: SimpleServiceStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.legacyRootURL = legacyRootURL.standardizedFileURL
    self.store = store
    self.now = now
  }

  public static func defaultSourceRoot() -> URL {
    let fileManager = FileManager.default
    let parent =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appending(
        path: "Library/Application Support",
        directoryHint: .isDirectory
      )
    return parent.appending(path: "CodexBridge", directoryHint: .isDirectory)
  }

  public func importIfNeeded() async throws -> LegacyImportReport {
    if try await store.hasConfigurationImportMarker(Self.markerKey) {
      return LegacyImportReport(
        status: .alreadyCompleted,
        sourceFound: true
      )
    }

    let date = now()
    let source = try LegacySourceReader(rootURL: legacyRootURL, date: date).read()
    guard source.sourceFound else {
      return LegacyImportReport(status: .noSource, sourceFound: false)
    }

    let batch = try ServiceConfigurationImportBatch(
      marker: ServiceSettingRecord(
        key: Self.markerKey,
        value: "1",
        updatedAt: date
      ),
      projects: source.projects,
      settings: source.settings
    )
    let result = try await store.importConfiguration(batch)
    if result.alreadyApplied {
      return LegacyImportReport(
        status: .alreadyCompleted,
        sourceFound: true,
        reducedProjects: source.reducedProjects
      )
    }
    return LegacyImportReport(
      status: .imported,
      sourceFound: true,
      insertedProjectIDs: result.insertedProjectIDs,
      existingProjectIDs: result.existingProjectIDs,
      reducedProjects: source.reducedProjects,
      insertedSettingKeys: result.insertedSettingKeys,
      existingSettingKeys: result.existingSettingKeys
    )
  }
}
