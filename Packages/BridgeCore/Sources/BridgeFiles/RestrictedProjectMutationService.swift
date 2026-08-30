import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation

public struct RestrictedProjectMutationService: Sendable {
  let repository: any ProjectRepository
  let writer = SecureProjectFileWriter()
  let directoryMutation = SecureProjectDirectoryMutation()
  let gitInspector = ProjectGitInspector()

  public init(repository: any ProjectRepository) {
    self.repository = repository
  }

  public func managePath(_ request: ProjectManagePathRequest) async throws
    -> ProjectMutationResult
  {
    let project = try await requireProject(request.projectID)
    let path = try securePath(request.relativePath)
    var destination: SecureRelativePath?
    if let destinationPath = request.destinationRelativePath {
      destination = try securePath(destinationPath)
    }
    let resolver = ProjectPathResolver(root: project.primaryRoot)

    let action: SecureDirectoryAction
    switch request.action {
    case .deleteFile:
      action = .deleteFile(expectedSHA256: request.expectedSHA256)
    case .moveFile:
      action = .moveFile(
        sourceExpectedSHA256: request.sourceExpectedSHA256,
        destinationExpectedAbsent: request.destinationExpectedAbsent
      )
    case .createDirectory:
      action = .createDirectory
    case .deleteEmptyDirectory:
      action = .deleteEmptyDirectory
    }
    let result = try mutationErrors {
      try directoryMutation.apply(
        action: action,
        relativePath: path,
        destinationRelativePath: destination,
        through: resolver
      )
    }
    return ProjectMutationResult(
      relativePath: path.value,
      destinationRelativePath: destination?.value,
      operation: request.action.rawValue,
      oldSHA256: result.revision?.sha256,
      newSHA256: nil,
      byteCount: result.revision?.byteCount ?? 0
    )
  }

  public func changes(projectID: ProjectID) async throws -> ProjectChangesResult {
    let project = try await requireProject(projectID)
    return try await gitInspector.changes(root: project.primaryRoot)
  }

  func mutationErrors<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as PathSecurityError {
      throw Self.mapSecurityError(error)
    }
  }

  static func mapSecurityError(_ error: PathSecurityError) -> ProjectMutationError {
    switch error {
    case .invalidRelativePath, .sensitiveFileBlocked, .pathEscapeBlocked:
      return .forbiddenPath
    case .rootUnavailable, .rootIdentityChanged, .fileIdentityChanged:
      return .unsafeFilesystemState
    case .pathDoesNotExist:
      return .pathMissing
    case .unsupportedFileType, .targetNotRegularFile:
      return .invalidRequest
    case .fileTooLarge:
      return .contentTooLarge
    case .binaryFileBlocked:
      return .binaryContent
    case .readFailed, .writeFailed:
      return .unsafeFilesystemState
    case .mutationAppliedDurabilityUncertain:
      return .durabilityUncertain
    case .targetAlreadyExists:
      return .pathExists
    case .unsupportedHardLink:
      return .unsupportedHardLink
    case .revisionConflict:
      return .revisionConflict
    case .pathChanged:
      return .pathChanged
    }
  }

  func textContent(_ value: String) throws -> Data {
    guard let data = value.data(using: .utf8) else { throw ProjectMutationError.binaryContent }
    guard !data.contains(0) else { throw ProjectMutationError.binaryContent }
    guard data.count <= writer.maximumBytes else { throw ProjectMutationError.contentTooLarge }
    return data
  }

  func securePath(_ value: String) throws -> SecureRelativePath {
    do {
      return try SecureRelativePath(value)
    } catch {
      throw ProjectMutationError.forbiddenPath
    }
  }

  func requireProject(_ id: ProjectID) async throws -> RegisteredProject {
    guard let project = try await repository.project(id: id) else {
      throw ProjectMutationError.unknownProject
    }
    try project.validateCurrentRoots()
    guard project.accessPolicy.read == .allowed else {
      throw ProjectMutationError.readNotAllowed
    }
    guard project.accessPolicy.write != .denied else {
      throw ProjectMutationError.writeNotAllowed
    }
    return project
  }
}
