import Foundation

enum SkillActionInterpreter {
  static func resolveInterpreter(_ name: String) -> String? {
    if name.hasPrefix("/") {
      guard FileManager.default.isExecutableFile(atPath: name) else { return nil }
      return name
    }
    return resolveExecutable(name)
  }

  static func interpreterForScript(
    url: URL,
    fileName: String,
    fileManager: FileManager
  ) throws -> String? {
    if let shebang = try shebangInterpreter(of: url.path, fileManager: fileManager) {
      return shebang
    }
    return extensionInterpreter(for: fileName)
  }

  static func shebangInterpreter(of path: String, fileManager: FileManager) throws -> String? {
    guard fileManager.isReadableFile(atPath: path),
      let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 256), !data.isEmpty,
      data[0] == 0x23, data.count >= 2, data[1] == 0x21
    else { return nil }
    guard let line = String(data: data, encoding: .utf8) else { return nil }
    let newlineIndex = line.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? line.endIndex
    var parts = line[line.startIndex..<newlineIndex].split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return nil }
    parts[0] = String(parts[0].dropFirst(2))
    guard !parts[0].isEmpty else { return nil }
    var command = parts[0]
    if command == "/usr/bin/env" {
      guard parts.count >= 2 else { return nil }
      command = parts[1]
    }
    if command.hasPrefix("/") {
      guard fileManager.isExecutableFile(atPath: command) else { return nil }
      return command
    }
    return resolveExecutable(command)
  }

  private static func extensionInterpreter(for fileName: String) -> String? {
    let lower = fileName.lowercased()
    if lower.hasSuffix(".sh") { return resolveExecutable("sh") }
    if lower.hasSuffix(".py") { return resolveExecutable("python3") }
    if lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs") || lower.hasSuffix(".js") {
      return resolveExecutable("node")
    }
    if lower.hasSuffix(".rb") { return resolveExecutable("ruby") }
    if lower.hasSuffix(".pl") { return resolveExecutable("perl") }
    return nil
  }

  private static func resolveExecutable(_ name: String) -> String? {
    guard !name.isEmpty, !name.contains("/"), name.utf8.count <= 4_096 else { return nil }
    let directories = [
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
      "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    for directory in directories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}
