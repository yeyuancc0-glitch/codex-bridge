import Foundation

struct DirectBuiltInCommandResolver: Sendable {
  private static let trustedSystemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

  let rules: [DirectCommandPolicy.DirectSafeCommandRule]

  var effectiveRules: [DirectCommandPolicy.DirectSafeCommandRule] {
    rules.filter { rule in
      !rule.executable.hasPrefix("/")
        && systemExecutable(for: [rule.executable] + rule.argumentsPrefix) != nil
    }
  }

  func systemExecutable(for argv: [String]) -> String? {
    guard let executable = argv.first, !executable.isEmpty, !executable.contains("/") else {
      return nil
    }
    let arguments = Array(argv.dropFirst())
    guard
      let matchedRule = rules.first(where: {
        $0.executable == executable && arguments.starts(with: $0.argumentsPrefix)
      })
    else { return nil }

    for candidate in candidates(for: matchedRule) {
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func candidates(
    for rule: DirectCommandPolicy.DirectSafeCommandRule
  ) -> [String] {
    var seen = Set<String>()
    let declared = rules.compactMap { candidate -> String? in
      let url = URL(fileURLWithPath: candidate.executable).standardizedFileURL
      guard candidate.executable.hasPrefix("/"),
        candidate.argumentsPrefix == rule.argumentsPrefix,
        url.lastPathComponent == rule.executable,
        Self.trustedSystemDirectories.contains(url.deletingLastPathComponent().path)
      else { return nil }
      return url.path
    }
    let conventional = Self.trustedSystemDirectories.map {
      URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(rule.executable).path
    }
    return (declared + conventional).filter { seen.insert($0).inserted }
  }
}
