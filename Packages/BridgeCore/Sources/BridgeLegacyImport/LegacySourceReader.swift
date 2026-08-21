import BridgeServiceCore
import Foundation

struct LegacySourceReader {
  let rootURL: URL
  let date: Date

  func read() throws -> LegacySourceSnapshot {
    let files = LegacySourceFiles(rootURL: rootURL)
    guard let directory = try files.openDirectory() else {
      return emptySnapshot
    }

    let repositoryFile = try directory.repositoryFile()
    let onboardingData = try directory.onboardingData()
    guard repositoryFile != nil || onboardingData != nil else {
      return emptySnapshot
    }

    let repository =
      try repositoryFile.map {
        try LegacyRepositoryReader(file: $0, importDate: date).read()
      } ?? LegacyRepositoryReadResult(projects: [], reducedProjects: [])
    let settings =
      try onboardingData.map {
        try LegacyOnboardingReader(data: $0, date: date).settings()
      } ?? []
    return LegacySourceSnapshot(
      sourceFound: true,
      projects: repository.projects,
      settings: settings,
      reducedProjects: repository.reducedProjects
    )
  }

  private var emptySnapshot: LegacySourceSnapshot {
    LegacySourceSnapshot(
      sourceFound: false,
      projects: [],
      settings: [],
      reducedProjects: []
    )
  }
}
