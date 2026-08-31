import BridgeSecurity
import Foundation

extension DirectCommandPolicy {
  func isProjectLocalExecutable(_ executable: String, projectRoot: String) -> Bool {
    guard DirectPathSemantics.hasSeparator(executable),
      let resolved = projectContainedPath(
        executable,
        projectRoot: projectRoot,
        workingDirectory: nil
      ),
      let root = DirectPathSemantics.resolvedPath(projectRoot)
    else { return false }
    return resolved != root || DirectPathSemantics.isExecutableFile(at: resolved)
  }

  func projectContainedPath(
    _ value: String,
    projectRoot: String,
    workingDirectory: String?
  ) -> String? {
    DirectPathSemantics.containedPath(
      value,
      projectRoot: projectRoot,
      workingDirectory: workingDirectory
    )
  }

  func safePathArgument(
    _ value: String,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    value == "-"
      || projectContainedPath(
        value,
        projectRoot: projectRoot,
        workingDirectory: workingDirectory
      ) != nil
  }

  private func listArgumentsAreSafe(
    _ arguments: ArraySlice<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var pathsEnabled = false
    for argument in arguments {
      if pathsEnabled {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
      } else if argument == "--" {
        pathsEnabled = true
      } else if argument.hasPrefix("-") && argument != "-" {
        continue
      } else {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
      }
    }
    return true
  }

  private func findArgumentsAreSafe(
    _ arguments: ArraySlice<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    let denied = Set([
      "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprint0",
      "-fprintf", "-L", "-H", "-follow",
    ])
    let valuePredicates = Set([
      "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-regex",
      "-iregex", "-type", "-size", "-mtime", "-atime", "-ctime", "-mmin", "-amin",
      "-cmin", "-user", "-group", "-perm", "-maxdepth", "-mindepth", "-fstype",
      "-inum", "-links", "-used", "-uid", "-gid",
    ])
    let predicates = Set([
      "!", "-not", "-a", "-and", "-o", "-or", "(", ")", "-print", "-print0", "-ls",
      "-xdev", "-mount", "-depth", "-d", "-prune", "-daystart", "-ignore_readdir_race",
      "-noignore_readdir_race", "-true", "-false", "-empty", "-readable", "-writable",
      "-executable",
    ])
    var expressionStarted = false
    var expectsValue = false
    var pathsEnabled = false
    for argument in arguments {
      if expectsValue {
        expectsValue = false
        continue
      }
      if pathsEnabled {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        continue
      }
      if argument == "--" {
        pathsEnabled = true
        continue
      }
      if !expressionStarted && !argument.hasPrefix("-") && argument != "!" && argument != "(" {
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        continue
      }
      expressionStarted = true
      guard !denied.contains(argument) else { return false }
      if valuePredicates.contains(argument) {
        expectsValue = true
      } else if !predicates.contains(argument) {
        return false
      }
    }
    return !expectsValue
  }

  func safeBuiltInInvocation(
    _ argv: [String],
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    guard let executable = argv.first else { return false }
    let basename = DirectPathSemantics.basename(executable)
    #if os(Windows)
      let commandName =
        basename.lowercased().hasSuffix(".exe")
        ? String(basename.dropLast(4)).lowercased()
        : basename.lowercased()
    #else
      let commandName = basename
    #endif
    switch commandName {
    case "pwd":
      return argv.dropFirst().allSatisfy { ["-L", "-P"].contains($0) }
    case "ls":
      return listArgumentsAreSafe(
        argv.dropFirst(), projectRoot: projectRoot, workingDirectory: workingDirectory)
    case "find":
      return findArgumentsAreSafe(
        argv.dropFirst(), projectRoot: projectRoot, workingDirectory: workingDirectory)
    case "grep", "rg":
      return DirectSearchArgumentValidator.areArgumentsSafe(
        executable: commandName,
        argv.dropFirst(),
        pathIsSafe: {
          safePathArgument(
            $0,
            projectRoot: projectRoot,
            workingDirectory: workingDirectory
          )
        }
      )
    case "git":
      let denied = [
        "--git-dir", "--work-tree", "--no-index", "--output", "--ext-diff", "--textconv",
        "--exec-path", "--config-env", "-C", "-c", "-p", "--paginate",
      ]
      return !argv.dropFirst().contains { argument in
        denied.contains(argument)
          || denied.dropLast().contains(where: { argument.hasPrefix($0 + "=") })
      }
    case "npm":
      let denied = [
        "--prefix", "--userconfig", "--globalconfig", "--cache", "--logs-dir", "--cafile",
        "--cert", "--key", "--script-shell", "--nodedir", "--tmp", "--workspace", "-w",
      ]
      return !argv.dropFirst().contains { argument in
        denied.contains(argument) || denied.contains { argument.hasPrefix($0 + "=") }
      }
    case "swift":
      return !containsOption(argv.dropFirst(), options: Self.swiftDeniedOptions)
        && pathOptionsAreContained(
          argv.dropFirst(), options: Self.swiftPathOptions, projectRoot: projectRoot,
          workingDirectory: workingDirectory
        )
    case "xcodebuild":
      return !containsOption(argv.dropFirst(), options: Self.xcodebuildDeniedOptions)
        && pathOptionsAreContained(
          argv.dropFirst(), options: Self.xcodebuildPathOptions, projectRoot: projectRoot,
          workingDirectory: workingDirectory
        )
        && responseFileOptionsAreContained(
          argv.dropFirst(), options: Self.xcodebuildResponseFileOptions,
          prefixes: Self.xcodebuildResponseFilePrefixes,
          projectRoot: projectRoot, workingDirectory: workingDirectory
        )
    default:
      return true
    }
  }

  private func containsOption(_ arguments: ArraySlice<String>, options: Set<String>) -> Bool {
    arguments.contains { argument in
      options.contains(argument)
        || options.contains { argument.hasPrefix($0 + "=") }
    }
  }

  private func pathOptionsAreContained(
    _ arguments: ArraySlice<String>,
    options: Set<String>,
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var expectsPath = false
    for argument in arguments {
      if expectsPath {
        guard !argument.hasPrefix("-") || argument == "-" else { return false }
        guard
          safePathArgument(argument, projectRoot: projectRoot, workingDirectory: workingDirectory)
        else { return false }
        expectsPath = false
      } else if let option = options.first(where: { argument == $0 || argument.hasPrefix($0 + "=") }
      ) {
        if argument == option {
          expectsPath = true
        } else {
          let value = String(argument.dropFirst(option.count + 1))
          guard
            safePathArgument(value, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
      }
    }
    return !expectsPath
  }

  private func responseFileOptionsAreContained(
    _ arguments: ArraySlice<String>,
    options: Set<String>,
    prefixes: [String],
    projectRoot: String,
    workingDirectory: String?
  ) -> Bool {
    var expectsValue = false
    for argument in arguments {
      if expectsValue {
        if argument.hasPrefix("@") {
          let path = String(argument.dropFirst())
          guard
            safePathArgument(path, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
        expectsValue = false
      } else if options.contains(argument) {
        expectsValue = true
      } else if let prefix = prefixes.first(where: { argument.hasPrefix($0) }) {
        let value = String(argument.dropFirst(prefix.count))
        if value.hasPrefix("@") {
          let path = String(value.dropFirst())
          guard
            safePathArgument(path, projectRoot: projectRoot, workingDirectory: workingDirectory)
          else { return false }
        }
      }
    }
    return !expectsValue
  }
}
