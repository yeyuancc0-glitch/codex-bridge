private enum SearchValueKind {
  case pattern
  case path
}

private struct SearchArgumentState {
  var patternSeen = false
  var filesMode = false
  var expectedValue: SearchValueKind?
  var pathsEnabled = false
}

enum DirectSearchArgumentValidator {
  private static let searchValueOptions = Set([
    "-e", "--regexp", "-f", "--file", "-g", "--glob", "--iglob", "--type", "-t",
    "--type-not", "-T", "--max-count", "-m", "--context", "-C", "-A", "-B",
    "--after-context", "--before-context", "--max-columns", "--max-depth",
    "--max-filesize", "--sort", "--sortr", "--threads", "-j", "--path-separator",
    "--glob-case", "--colors", "--color", "--include", "--exclude", "--exclude-dir",
  ])
  private static let searchPathOptions = Set(["-f", "--file"])
  private static let searchFlags = Set([
    "-a", "--text", "-b", "--byte-offset", "-c", "--count", "-h", "--no-filename",
    "-H", "--with-filename", "-i", "--ignore-case", "-l", "--files-with-matches",
    "-L", "--files-without-match", "-n", "--line-number", "-q", "--quiet", "-r",
    "--replace", "-R", "--follow", "-s", "--no-messages", "-v", "--invert-match",
    "-w", "--word-regexp", "-x", "--line-regexp", "-F", "--fixed-strings", "-E",
    "--encoding", "--hidden", "--no-ignore", "--no-ignore-vcs", "--files",
    "--glob-case-insensitive", "--stats", "--json", "--heading", "--no-heading",
    "--trim", "--crlf", "--null", "--null-data", "--passthru", "--binary-files",
  ])
  private static let deniedSearchOptionPrefixes = ["--pre", "--hostname-bin"]

  static func areArgumentsSafe(
    executable: String,
    _ arguments: ArraySlice<String>,
    pathIsSafe: (String) -> Bool
  ) -> Bool {
    var state = SearchArgumentState()
    for argument in arguments {
      guard
        consumeSearchArgument(
          argument,
          executable: executable,
          pathIsSafe: pathIsSafe,
          state: &state
        )
      else { return false }
    }
    return state.expectedValue == nil
  }

  private static func consumeSearchArgument(
    _ argument: String,
    executable: String,
    pathIsSafe: (String) -> Bool,
    state: inout SearchArgumentState
  ) -> Bool {
    if let expectedValue = state.expectedValue {
      state.expectedValue = nil
      return consumeSearchValue(
        argument,
        kind: expectedValue,
        pathIsSafe: pathIsSafe,
        state: &state
      )
    }
    if state.pathsEnabled {
      return pathIsSafe(argument)
    }
    if argument == "--" {
      state.pathsEnabled = true
      return true
    }
    if argument == "--files" && executable == "rg" {
      state.filesMode = true
      return true
    }
    if argument.hasPrefix("-") && argument != "-" {
      return consumeSearchOption(argument, pathIsSafe: pathIsSafe, state: &state)
    }
    if state.filesMode || state.patternSeen {
      return pathIsSafe(argument)
    }
    state.patternSeen = true
    return true
  }

  private static func consumeSearchValue(
    _ value: String,
    kind: SearchValueKind,
    pathIsSafe: (String) -> Bool,
    state: inout SearchArgumentState
  ) -> Bool {
    switch kind {
    case .pattern:
      state.patternSeen = true
      return true
    case .path:
      return pathIsSafe(value)
    }
  }

  private static func consumeSearchOption(
    _ argument: String,
    pathIsSafe: (String) -> Bool,
    state: inout SearchArgumentState
  ) -> Bool {
    guard
      !deniedSearchOptionPrefixes.contains(where: {
        argument == $0 || argument.hasPrefix($0 + "=")
      })
    else { return false }
    let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    let option = String(parts[0])
    let inlineValue = parts.count == 2 ? String(parts[1]) : nil
    if searchValueOptions.contains(option) {
      return consumeSearchValueOption(
        option,
        inlineValue: inlineValue,
        pathIsSafe: pathIsSafe,
        state: &state
      )
    }
    guard !searchFlags.contains(option) else { return true }
    return shortSearchFlagClusterIsSafe(option)
  }

  private static func consumeSearchValueOption(
    _ option: String,
    inlineValue: String?,
    pathIsSafe: (String) -> Bool,
    state: inout SearchArgumentState
  ) -> Bool {
    let kind: SearchValueKind = searchPathOptions.contains(option) ? .path : .pattern
    guard let inlineValue else {
      state.expectedValue = kind
      return true
    }
    return consumeSearchValue(
      inlineValue,
      kind: kind,
      pathIsSafe: pathIsSafe,
      state: &state
    )
  }

  private static func shortSearchFlagClusterIsSafe(_ option: String) -> Bool {
    guard option.count > 2, option.first == "-", !option.hasPrefix("--") else { return false }
    return option.dropFirst().allSatisfy { searchFlags.contains("-\($0)") }
  }
}
