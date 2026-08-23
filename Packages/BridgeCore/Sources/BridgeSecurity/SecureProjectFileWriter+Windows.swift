#if canImport(WinSDK)
  import Foundation

  public struct SecureProjectFileWriter: Sendable {
    public let maximumBytes: Int

    public init(maximumBytes: Int = 200 * 1_024) {
      self.maximumBytes = max(1, maximumBytes)
    }

    public func write(
      relativePath: SecureRelativePath,
      through resolver: ProjectPathResolver,
      mode: SecureWriteMode,
      content: Data,
      expectedSHA256: String?,
      createParents: Bool
    ) throws -> SecureWriteResult {
      try validateContent(content)
      try resolver.root.validateCurrentIdentity()
      try WindowsSecurePathRules.validate(relativePath)
      guard resolver.sensitivePolicy.allows(relativePath) else {
        throw PathSecurityError.sensitiveFileBlocked
      }

      let (parent, name) = try WindowsSecureMutationSupport.parentLease(
        relativePath: relativePath,
        root: resolver.root,
        createParents: createParents
      )
      let targetPath = WindowsSecureMutationSupport.join(parent.path, name)
      switch mode {
      case .create:
        return try create(
          targetPath: targetPath,
          parentPath: parent.path,
          content: content,
          root: resolver.root
        )
      case .replace:
        return try replace(
          targetPath: targetPath,
          parentPath: parent.path,
          content: content,
          expectedSHA256: expectedSHA256,
          root: resolver.root
        )
      }
    }

    public func revision(
      relativePath: SecureRelativePath,
      through resolver: ProjectPathResolver
    ) throws -> SecureFileRevision? {
      try resolver.root.validateCurrentIdentity()
      try WindowsSecurePathRules.validate(relativePath)
      guard resolver.sensitivePolicy.allows(relativePath) else {
        throw PathSecurityError.sensitiveFileBlocked
      }
      do {
        let (parent, name) = try WindowsSecureMutationSupport.parentLease(
          relativePath: relativePath,
          root: resolver.root,
          createParents: false
        )
        let path = WindowsSecureMutationSupport.join(parent.path, name)
        guard
          let handle = try WindowsSecureMutationSupport.optionalRegularFile(
            path: path,
            root: resolver.root
          )
        else { return nil }
        defer { handle.close() }
        let snapshot = try WindowsSecureMutationSupport.validateRegularFile(
          handle: handle.value,
          expectedPath: path,
          root: resolver.root
        )
        guard snapshot.byteCount <= maximumBytes else {
          throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
        }
        let data = try WindowsSecureMutationSupport.readAll(
          handle: handle.value,
          maximumBytes: maximumBytes
        )
        return .digest(of: data)
      } catch PathSecurityError.pathDoesNotExist {
        return nil
      }
    }

    public func readContent(
      relativePath: SecureRelativePath,
      through resolver: ProjectPathResolver
    ) throws -> Data? {
      try resolver.root.validateCurrentIdentity()
      try WindowsSecurePathRules.validate(relativePath)
      guard resolver.sensitivePolicy.allows(relativePath) else {
        throw PathSecurityError.sensitiveFileBlocked
      }
      do {
        let (parent, name) = try WindowsSecureMutationSupport.parentLease(
          relativePath: relativePath,
          root: resolver.root,
          createParents: false
        )
        let path = WindowsSecureMutationSupport.join(parent.path, name)
        guard
          let handle = try WindowsSecureMutationSupport.optionalRegularFile(
            path: path,
            root: resolver.root
          )
        else { return nil }
        defer { handle.close() }
        let snapshot = try WindowsSecureMutationSupport.validateRegularFile(
          handle: handle.value,
          expectedPath: path,
          root: resolver.root
        )
        guard snapshot.byteCount <= maximumBytes else {
          throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
        }
        return try WindowsSecureMutationSupport.readAll(
          handle: handle.value,
          maximumBytes: maximumBytes
        )
      } catch PathSecurityError.pathDoesNotExist {
        return nil
      }
    }

    private func create(
      targetPath: String,
      parentPath: String,
      content: Data,
      root: RegisteredRoot
    ) throws -> SecureWriteResult {
      let staging = try stage(content: content, parentPath: parentPath, root: root)
      do {
        try WindowsSecureMutationSupport.move(
          sourcePath: staging,
          destinationPath: targetPath,
          replaceExisting: false
        )
      } catch {
        WindowsSecureMutationSupport.cleanupFile(path: staging)
        throw error
      }
      let revision = SecureFileRevision.digest(of: content)
      try verify(path: targetPath, expectedRevision: revision, root: root)
      return SecureWriteResult(mode: .create, oldRevision: nil, newRevision: revision)
    }

    private func replace(
      targetPath: String,
      parentPath: String,
      content: Data,
      expectedSHA256: String?,
      root: RegisteredRoot
    ) throws -> SecureWriteResult {
      let original = try WindowsSecureMutationSupport.readRegularFile(
        path: targetPath,
        root: root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      let oldRevision = SecureFileRevision.digest(of: original.data)
      if let expectedSHA256, expectedSHA256 != oldRevision.sha256 {
        throw PathSecurityError.revisionConflict
      }

      let staging = try stage(content: content, parentPath: parentPath, root: root)
      do {
        let current = try WindowsSecureMutationSupport.readRegularFile(
          path: targetPath,
          root: root,
          maximumBytes: maximumBytes,
          requireSingleLink: true
        )
        guard current.snapshot.identity == original.snapshot.identity,
          SecureFileRevision.digest(of: current.data) == oldRevision
        else {
          throw PathSecurityError.pathChanged
        }
        try WindowsSecureMutationSupport.move(
          sourcePath: staging,
          destinationPath: targetPath,
          replaceExisting: true
        )
      } catch {
        WindowsSecureMutationSupport.cleanupFile(path: staging)
        throw error
      }

      let newRevision = SecureFileRevision.digest(of: content)
      try verify(path: targetPath, expectedRevision: newRevision, root: root)
      return SecureWriteResult(
        mode: .replace,
        oldRevision: oldRevision,
        newRevision: newRevision
      )
    }

    private func stage(
      content: Data,
      parentPath: String,
      root: RegisteredRoot
    ) throws -> String {
      let staging = try WindowsSecureMutationSupport.createStagingFile(
        parentPath: parentPath,
        root: root
      )
      do {
        try WindowsSecureMutationSupport.writeAll(handle: staging.handle.value, data: content)
        try WindowsSecureMutationSupport.flush(handle: staging.handle.value)
        staging.handle.close()
        return staging.path
      } catch {
        staging.handle.close()
        WindowsSecureMutationSupport.cleanupFile(path: staging.path)
        throw error
      }
    }

    private func verify(
      path: String,
      expectedRevision: SecureFileRevision,
      root: RegisteredRoot
    ) throws {
      try root.validateCurrentIdentity()
      let final = try WindowsSecureMutationSupport.readRegularFile(
        path: path,
        root: root,
        maximumBytes: maximumBytes,
        requireSingleLink: true
      )
      guard SecureFileRevision.digest(of: final.data) == expectedRevision else {
        throw PathSecurityError.pathChanged
      }
    }

    private func validateContent(_ content: Data) throws {
      guard content.count <= maximumBytes else {
        throw PathSecurityError.fileTooLarge(maximumBytes: maximumBytes)
      }
      guard String(data: content, encoding: .utf8) != nil, !content.contains(0) else {
        throw PathSecurityError.binaryFileBlocked
      }
    }
  }
#endif
