public enum AgentPathStyle: Equatable, Sendable {
  case posix
  case windows

  public static var current: Self {
    #if os(Windows)
      return .windows
    #else
      return .posix
    #endif
  }

  var listSeparator: Character {
    self == .windows ? ";" : ":"
  }

  var pathSeparator: Character {
    self == .windows ? "\\" : "/"
  }
}
