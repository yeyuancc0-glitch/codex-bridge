import Foundation

public enum WindowsCommandLineError: Error, Equatable, Sendable {
  case emptyInvocation
  case invalidNullCharacter
}

/// Encodes structured argv for the Microsoft C runtime parsing rules used by
/// native Windows executables. This is deliberately not a cmd.exe encoder.
public struct WindowsCommandLine: Sendable {
  public static func encode(_ arguments: [String]) throws -> String {
    guard !arguments.isEmpty else { throw WindowsCommandLineError.emptyInvocation }
    guard arguments.allSatisfy({ !$0.contains("\0") }) else {
      throw WindowsCommandLineError.invalidNullCharacter
    }
    return arguments.map(quote).joined(separator: " ")
  }

  private static func quote(_ argument: String) -> String {
    guard argument.isEmpty || argument.contains(where: needsQuoting) else { return argument }

    var result = "\""
    var backslashCount = 0
    for scalar in argument.unicodeScalars {
      if scalar == "\\" {
        backslashCount += 1
        continue
      }
      if scalar == "\"" {
        result.append(String(repeating: "\\", count: backslashCount * 2 + 1))
        result.unicodeScalars.append(scalar)
      } else {
        result.append(String(repeating: "\\", count: backslashCount))
        result.unicodeScalars.append(scalar)
      }
      backslashCount = 0
    }
    result.append(String(repeating: "\\", count: backslashCount * 2))
    result.append("\"")
    return result
  }

  private static func needsQuoting(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\n" || character == "\""
  }
}
