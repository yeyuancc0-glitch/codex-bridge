import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
  import ucrt
#endif

extension ManagedStdioProcess {
  static func spawn(
    argv: [String],
    workingDirectory: String?,
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32,
    standardError: Int32
  ) throws -> pid_t {
    #if canImport(Darwin)
      return try spawnDarwin(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
    #else
      return try spawnGlibc(
        argv: argv,
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
    #endif
  }

  #if os(Windows)
    /// Windows spawn: Foundation.Process wires the anonymous pipes and owns the
    /// child handle; ManagedStdioProcess keeps the object for wait/terminate.
    static func spawnWindows(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Pipe,
      standardOutput: Pipe,
      standardError: Pipe?
    ) throws -> Foundation.Process {
      guard let executable = argv.first else {
        throw ManagedProcessError.invalidArgument
      }
      let process = Foundation.Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = Array(argv.dropFirst())
      process.environment = environment
      if let workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      }
      process.standardInput = standardInput
      process.standardOutput = standardOutput
      if let standardError {
        process.standardError = standardError
      } else {
        process.standardError = standardOutput
      }
      do {
        try process.run()
      } catch {
        throw ManagedProcessError.processLaunchFailed(Int32(ERROR_FILE_NOT_FOUND))
      }
      return process
    }
  #endif

  #if canImport(Darwin)
    static func spawnDarwin(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws -> pid_t {
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawnattr_destroy(&attributes) }

      try configureDarwinActions(
        &actions,
        workingDirectory: workingDirectory,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError
      )
      let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      return try performSpawn(
        executable: argv[0],
        argv: argv,
        environment: environment,
        actions: &actions,
        attributes: &attributes
      )
    }

    static func configureDarwinActions(
      _ actions: inout posix_spawn_file_actions_t?,
      workingDirectory: String?,
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws {
      guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, standardInput) == 0,
        posix_spawn_file_actions_addclose(&actions, standardOutput) == 0,
        standardError == standardOutput
          || posix_spawn_file_actions_addclose(&actions, standardError) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      if let workingDirectory {
        let result: Int32
        if #available(macOS 26.0, *) {
          result = posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        } else {
          result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }
        guard result == 0 else { throw ManagedProcessError.processLaunchFailed(result) }
      }
    }

    static func performSpawn(
      executable: String,
      argv: [String],
      environment: [String: String],
      actions: inout posix_spawn_file_actions_t?,
      attributes: inout posix_spawnattr_t?
    ) throws -> pid_t {
      let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      return try withCStringArray(argv) { argvPointer in
        try withCStringArray(entries) { environmentPointer in
          var processID: pid_t = 0
          let result = posix_spawn(
            &processID,
            executable,
            &actions,
            &attributes,
            argvPointer,
            environmentPointer
          )
          guard result == 0, processID > 1 else {
            throw ManagedProcessError.processLaunchFailed(result)
          }
          return processID
        }
      }
    }
  #elseif canImport(Glibc)
    static func spawnGlibc(
      argv: [String],
      workingDirectory: String?,
      environment: [String: String],
      standardInput: Int32,
      standardOutput: Int32,
      standardError: Int32
    ) throws -> pid_t {
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
      guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawn_file_actions_destroy(&actions) }
      guard posix_spawnattr_init(&attributes) == 0 else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      defer { posix_spawnattr_destroy(&attributes) }

      guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&actions, standardInput) == 0,
        posix_spawn_file_actions_addclose(&actions, standardOutput) == 0,
        standardError == standardOutput
          || posix_spawn_file_actions_addclose(&actions, standardError) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }
      if let workingDirectory {
        let result = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        guard result == 0 else { throw ManagedProcessError.processLaunchFailed(result) }
      }
      let flags = Int16(POSIX_SPAWN_SETPGROUP)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0
      else {
        throw ManagedProcessError.processLaunchFailed(Int32(errno))
      }

      let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      return try withCStringArray(argv) { argvPointer in
        try withCStringArray(entries) { environmentPointer in
          var processID: pid_t = 0
          let result = posix_spawn(
            &processID,
            argv[0],
            &actions,
            &attributes,
            argvPointer,
            environmentPointer
          )
          guard result == 0, processID > 1 else {
            throw ManagedProcessError.processLaunchFailed(result)
          }
          return processID
        }
      }
    }
  #endif

  static func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    #if os(Windows)
      var storage = strings.map { _strdup($0) }
    #else
      var storage = strings.map { strdup($0) }
    #endif
    defer { for pointer in storage { free(pointer) } }
    storage.append(nil)
    return try storage.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}
