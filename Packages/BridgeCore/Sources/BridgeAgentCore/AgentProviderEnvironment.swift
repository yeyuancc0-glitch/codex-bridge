import Foundation

public enum AgentProviderEnvironment {
  public static func homeDirectory(
    source: [String: String],
    field: String = "environment.HOME"
  ) throws -> String {
    let value = source["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 16 * 1_024 else {
      throw AgentRuntimeError.invalidRequest(field)
    }
    return URL(fileURLWithPath: value, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
  }

  public static func executableSearchPath(
    executablePath: String,
    sourcePath: String?
  ) -> String {
    let inherited = (sourcePath ?? "")
      .split(separator: ":")
      .map(String.init)
      .filter(isUsableSearchDirectory)
    let candidates =
      [
        URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
      ] + inherited + [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
      ]
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }.joined(separator: ":")
  }

  private static func isUsableSearchDirectory(_ value: String) -> Bool {
    value.hasPrefix("/") && value.utf8.count <= 16 * 1_024
      && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
}
