import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#endif

#if os(Windows)
  struct GitAttributeScanner {
    private let maximumEntries = 100_000
    private let maximumAttributeFiles = 1_024
    private let maximumFileBytes = 256 * 1_024
    private let maximumTotalBytes = 1_024 * 1_024
    private let maximumDepth = 128
    private var visitedEntries = 0
    private var totalBytes = 0
    private var files: [Data] = []

    mutating func scan(rootPath: String) throws -> [Data] {
      try scanDirectory(path: rootPath, depth: 0)
      return files
    }

    private mutating func scanDirectory(path: String, depth: Int) throws {
      guard depth <= maximumDepth else { throw GitEvidenceError.pathByteLimitExceeded }
      for name in try directoryEntries(path: path) {
        try inspect(name: name, in: path, depth: depth)
      }
    }

    private mutating func inspect(
      name: String,
      in directoryPath: String,
      depth: Int
    ) throws {
      visitedEntries += 1
      guard visitedEntries <= maximumEntries else {
        throw GitEvidenceError.fileCountLimitExceeded
      }
      let attributes = Self.entryAttributes(directoryPath + "\\" + name)
      guard let attributes else { throw GitEvidenceError.unsafeGitAttributes }
      if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return }
      if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0, name != ".git" {
        try scanChildDirectory(name: name, in: directoryPath, depth: depth + 1)
        return
      }
      guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0, name == ".gitattributes"
      else { return }
      try appendAttributeFile(name: name, in: directoryPath)
    }

    private mutating func scanChildDirectory(
      name: String,
      in directoryPath: String,
      depth: Int
    ) throws {
      let childPath = directoryPath + "\\" + name
      let handle = Self.openDirectory(childPath)
      guard handle != INVALID_HANDLE_VALUE else {
        throw GitEvidenceError.unsafeGitAttributes
      }
      _ = CloseHandle(handle)
      try scanDirectory(path: childPath, depth: depth)
    }

    private mutating func appendAttributeFile(
      name: String,
      in directoryPath: String
    ) throws {
      guard files.count < maximumAttributeFiles else {
        throw GitEvidenceError.fileCountLimitExceeded
      }
      let handle: HANDLE = (directoryPath + "\\" + name).withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(GENERIC_READ),
          DWORD(FILE_SHARE_READ),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
      guard handle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.unsafeGitAttributes }
      defer { _ = CloseHandle(handle) }
      let contents = try Self.read(
        handle: handle,
        maximumBytes: maximumFileBytes
      )
      guard totalBytes <= maximumTotalBytes - contents.count else {
        throw GitEvidenceError.commandOutputLimitExceeded
      }
      totalBytes += contents.count
      files.append(contents)
    }

    private static func openDirectory(_ path: String) -> HANDLE {
      path.withCString(encodedAs: UTF16.self) {
        CreateFileW(
          $0,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
          nil
        )
      }
    }

    private static func entryAttributes(_ path: String) -> DWORD? {
      let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
      return attributes == INVALID_FILE_ATTRIBUTES ? nil : attributes
    }

    private static func read(handle: HANDLE, maximumBytes: Int) throws -> Data {
      var information = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &information),
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0,
        information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw GitEvidenceError.unsafeGitAttributes
      }
      let size = (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow)
      guard size <= UInt64(maximumBytes) else { throw GitEvidenceError.unsafeGitAttributes }
      var output = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while true {
        var received: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes { bytes in
          ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &received, nil)
        }
        guard succeeded else { throw GitEvidenceError.unsafeGitAttributes }
        if received == 0 { return output }
        output.append(contentsOf: buffer.prefix(Int(received)))
      }
    }

    private mutating func directoryEntries(path: String) throws -> [String] {
      let pattern = path + "\\*"
      var findData = WIN32_FIND_DATAW()
      let findHandle: HANDLE = pattern.withCString(encodedAs: UTF16.self) {
        FindFirstFileW($0, &findData)
      }
      guard findHandle != INVALID_HANDLE_VALUE else { throw GitEvidenceError.unsafeGitAttributes }
      defer { _ = FindClose(findHandle) }
      var names: [String] = []
      repeat {
        let name = withUnsafeBytes(of: &findData.cFileName) { raw in
          String(
            decodingCString: raw.bindMemory(to: UTF16.CodeUnit.self).baseAddress!, as: UTF16.self)
        }
        if name != "." && name != ".." { names.append(name) }
      } while FindNextFileW(findHandle, &findData)
      guard GetLastError() == DWORD(ERROR_NO_MORE_FILES) else {
        throw GitEvidenceError.unsafeGitAttributes
      }
      return names.sorted()
    }
  }
#else
  struct GitAttributeScanner {
    private let maximumEntries = 100_000
    private let maximumAttributeFiles = 1_024
    private let maximumFileBytes = 256 * 1_024
    private let maximumTotalBytes = 1_024 * 1_024
    private let maximumDepth = 128
    private var visitedEntries = 0
    private var totalBytes = 0
    private var files: [Data] = []

    mutating func scan(rootDescriptor: Int32) throws -> [Data] {
      try scanDirectory(descriptor: rootDescriptor, depth: 0)
      return files
    }

    private mutating func scanDirectory(descriptor: Int32, depth: Int) throws {
      guard depth <= maximumDepth else { throw GitEvidenceError.pathByteLimitExceeded }
      let duplicate = dup(descriptor)
      guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { Darwin.close(duplicate) }
        throw GitEvidenceError.unsafeGitAttributes
      }
      defer { closedir(directory) }

      errno = 0
      while let entry = readdir(directory) {
        let name = Self.entryName(entry)
        if name == "." || name == ".." { continue }
        try inspect(name: name, in: descriptor, depth: depth)
        errno = 0
      }
      guard errno == 0 else { throw GitEvidenceError.unsafeGitAttributes }
    }

    private mutating func inspect(
      name: String,
      in directoryDescriptor: Int32,
      depth: Int
    ) throws {
      visitedEntries += 1
      guard visitedEntries <= maximumEntries else {
        throw GitEvidenceError.fileCountLimitExceeded
      }
      var information = stat()
      let result = name.withCString {
        fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
      }
      guard result == 0 else { throw GitEvidenceError.unsafeGitAttributes }
      let type = information.st_mode & S_IFMT
      if type == S_IFDIR, name != ".git" {
        try scanChildDirectory(name: name, in: directoryDescriptor, depth: depth + 1)
        return
      }
      guard type == S_IFREG, name == ".gitattributes" else { return }
      try appendAttributeFile(name: name, in: directoryDescriptor)
    }

    private mutating func scanChildDirectory(
      name: String,
      in directoryDescriptor: Int32,
      depth: Int
    ) throws {
      let child = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else { throw GitEvidenceError.unsafeGitAttributes }
      defer { Darwin.close(child) }
      try scanDirectory(descriptor: child, depth: depth)
    }

    private mutating func appendAttributeFile(
      name: String,
      in directoryDescriptor: Int32
    ) throws {
      guard files.count < maximumAttributeFiles else {
        throw GitEvidenceError.fileCountLimitExceeded
      }
      let descriptor = name.withCString {
        openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { throw GitEvidenceError.unsafeGitAttributes }
      defer { Darwin.close(descriptor) }
      let contents = try Self.read(
        descriptor: descriptor,
        maximumBytes: maximumFileBytes
      )
      guard totalBytes <= maximumTotalBytes - contents.count else {
        throw GitEvidenceError.commandOutputLimitExceeded
      }
      totalBytes += contents.count
      files.append(contents)
    }

    private static func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
      var information = stat()
      guard fstat(descriptor, &information) == 0,
        information.st_mode & S_IFMT == S_IFREG,
        information.st_size >= 0,
        information.st_size <= maximumBytes
      else {
        throw GitEvidenceError.unsafeGitAttributes
      }
      var output = Data()
      var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
      while output.count <= maximumBytes {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return output }
        if count > 0 {
          output.append(contentsOf: buffer.prefix(count))
          continue
        }
        if errno == EINTR { continue }
        throw GitEvidenceError.unsafeGitAttributes
      }
      throw GitEvidenceError.unsafeGitAttributes
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
      withUnsafePointer(to: &entry.pointee.d_name) { name in
        name.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
          String(cString: $0)
        }
      }
    }
  }
#endif
