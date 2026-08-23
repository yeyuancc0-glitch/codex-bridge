#if canImport(WinSDK)
  import Foundation

  public struct SecureProjectDirectoryMutation: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = 200 * 1_024) {
      self.maximumBytes = max(1, maximumBytes)
    }

    public func apply(
      action: SecureDirectoryAction,
      relativePath: SecureRelativePath,
      destinationRelativePath: SecureRelativePath?,
      through resolver: ProjectPathResolver
    ) throws -> SecureDirectoryMutationResult {
      try resolver.root.validateCurrentIdentity()
      try WindowsSecurePathRules.validate(relativePath)
      guard resolver.sensitivePolicy.allows(relativePath) else {
        throw PathSecurityError.sensitiveFileBlocked
      }
      if let destinationRelativePath {
        try WindowsSecurePathRules.validate(destinationRelativePath)
        guard resolver.sensitivePolicy.allows(destinationRelativePath) else {
          throw PathSecurityError.sensitiveFileBlocked
        }
      }

      switch action {
      case .deleteFile(let expectedSHA256):
        return try deleteFile(
          relativePath: relativePath,
          expectedSHA256: expectedSHA256,
          resolver: resolver
        )
      case .moveFile(let sourceExpectedSHA256, let destinationExpectedAbsent):
        guard let destinationRelativePath else {
          throw PathSecurityError.invalidRelativePath("missing destination")
        }
        return try moveFile(
          sourcePath: relativePath,
          destinationPath: destinationRelativePath,
          sourceExpectedSHA256: sourceExpectedSHA256,
          destinationExpectedAbsent: destinationExpectedAbsent,
          resolver: resolver
        )
      case .createDirectory:
        return try createDirectory(relativePath: relativePath, resolver: resolver)
      case .deleteEmptyDirectory:
        return try deleteEmptyDirectory(relativePath: relativePath, resolver: resolver)
      }
    }

    private func deleteFile(
      relativePath: SecureRelativePath,
      expectedSHA256: String?,
      resolver: ProjectPathResolver
    ) throws -> SecureDirectoryMutationResult {
      let (parent, name) = try WindowsSecureMutationSupport.parentLease(
        relativePath: relativePath,
        root: resolver.root,
        createParents: false
      )
      let path = WindowsSecureMutationSupport.join(parent.path, name)
      let original = try WindowsSecureMutationSupport.readRegularFile(
        path: path,
        root: resolver.root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      let revision = SecureFileRevision.digest(of: original.data)
      if let expectedSHA256, expectedSHA256 != revision.sha256 {
        throw PathSecurityError.revisionConflict
      }
      let current = try WindowsSecureMutationSupport.readRegularFile(
        path: path,
        root: resolver.root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      guard current.snapshot.identity == original.snapshot.identity,
        SecureFileRevision.digest(of: current.data) == revision
      else {
        throw PathSecurityError.pathChanged
      }

      try WindowsSecureMutationSupport.deleteFile(path: path)
      guard try WindowsSecureMutationSupport.fileIdentity(path: path, root: resolver.root) == nil
      else {
        throw PathSecurityError.pathChanged
      }
      try resolver.root.validateCurrentIdentity()
      return SecureDirectoryMutationResult(
        action: .deleteFile(expectedSHA256: expectedSHA256),
        revision: revision
      )
    }

    private func moveFile(
      sourcePath: SecureRelativePath,
      destinationPath: SecureRelativePath,
      sourceExpectedSHA256: String?,
      destinationExpectedAbsent: Bool,
      resolver: ProjectPathResolver
    ) throws -> SecureDirectoryMutationResult {
      guard sourcePath != destinationPath else {
        throw PathSecurityError.invalidRelativePath("source and destination are identical")
      }
      let (sourceParent, sourceName) = try WindowsSecureMutationSupport.parentLease(
        relativePath: sourcePath,
        root: resolver.root,
        createParents: false
      )
      let (destinationParent, destinationName) = try WindowsSecureMutationSupport.parentLease(
        relativePath: destinationPath,
        root: resolver.root,
        createParents: false
      )
      let source = WindowsSecureMutationSupport.join(sourceParent.path, sourceName)
      let destination = WindowsSecureMutationSupport.join(
        destinationParent.path,
        destinationName
      )

      let original = try WindowsSecureMutationSupport.readRegularFile(
        path: source,
        root: resolver.root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      let revision = SecureFileRevision.digest(of: original.data)
      if let sourceExpectedSHA256, sourceExpectedSHA256 != revision.sha256 {
        throw PathSecurityError.revisionConflict
      }

      if let destinationHandle = try WindowsSecureMutationSupport.optionalRegularFile(
        path: destination,
        root: resolver.root
      ) {
        defer { destinationHandle.close() }
        let destinationSnapshot = try WindowsSecureMutationSupport.validateRegularFile(
          handle: destinationHandle.value,
          expectedPath: destination,
          root: resolver.root
        )
        if destinationExpectedAbsent { throw PathSecurityError.targetAlreadyExists }
        guard destinationSnapshot.linkCount <= 1 else {
          throw PathSecurityError.unsupportedHardLink
        }
      }

      let current = try WindowsSecureMutationSupport.readRegularFile(
        path: source,
        root: resolver.root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      guard current.snapshot.identity == original.snapshot.identity,
        SecureFileRevision.digest(of: current.data) == revision
      else {
        throw PathSecurityError.pathChanged
      }

      try WindowsSecureMutationSupport.move(
        sourcePath: source,
        destinationPath: destination,
        replaceExisting: !destinationExpectedAbsent
      )
      let moved = try WindowsSecureMutationSupport.readRegularFile(
        path: destination,
        root: resolver.root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      guard SecureFileRevision.digest(of: moved.data) == revision,
        try WindowsSecureMutationSupport.fileIdentity(path: source, root: resolver.root) == nil
      else {
        throw PathSecurityError.pathChanged
      }
      try resolver.root.validateCurrentIdentity()
      return SecureDirectoryMutationResult(
        action: .moveFile(
          sourceExpectedSHA256: sourceExpectedSHA256,
          destinationExpectedAbsent: destinationExpectedAbsent
        ),
        revision: revision
      )
    }

    private func createDirectory(
      relativePath: SecureRelativePath,
      resolver: ProjectPathResolver
    ) throws -> SecureDirectoryMutationResult {
      let (parent, name) = try WindowsSecureMutationSupport.parentLease(
        relativePath: relativePath,
        root: resolver.root,
        createParents: false
      )
      let path = WindowsSecureMutationSupport.join(parent.path, name)
      try WindowsSecureMutationSupport.createDirectory(path: path, allowExisting: false)
      do {
        _ = try WindowsSecureMutationSupport.directoryIdentity(
          components: relativePath.components,
          root: resolver.root
        )
      } catch {
        try? WindowsSecureMutationSupport.removeDirectory(path: path)
        throw error
      }
      try resolver.root.validateCurrentIdentity()
      return SecureDirectoryMutationResult(action: .createDirectory, revision: nil)
    }

    private func deleteEmptyDirectory(
      relativePath: SecureRelativePath,
      resolver: ProjectPathResolver
    ) throws -> SecureDirectoryMutationResult {
      let (parent, name) = try WindowsSecureMutationSupport.parentLease(
        relativePath: relativePath,
        root: resolver.root,
        createParents: false
      )
      let path = WindowsSecureMutationSupport.join(parent.path, name)
      let original = try WindowsSecureMutationSupport.directoryIdentity(
        components: relativePath.components,
        root: resolver.root
      )
      let current = try WindowsSecureMutationSupport.directoryIdentity(
        components: relativePath.components,
        root: resolver.root
      )
      guard current == original else { throw PathSecurityError.pathChanged }
      try WindowsSecureMutationSupport.removeDirectory(path: path)
      do {
        _ = try WindowsSecureMutationSupport.directoryIdentity(
          components: relativePath.components,
          root: resolver.root
        )
        throw PathSecurityError.pathChanged
      } catch PathSecurityError.pathDoesNotExist {
      }
      try resolver.root.validateCurrentIdentity()
      return SecureDirectoryMutationResult(action: .deleteEmptyDirectory, revision: nil)
    }
  }
#endif
