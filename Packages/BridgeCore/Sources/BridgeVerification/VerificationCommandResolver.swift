import BridgeProjects
import Foundation

struct ResolvedVerificationCommand: Sendable {
  let index: Int
  let identifier: VerificationCommandIdentifier
  let command: VerificationCommand

  var argv: [String] {
    [command.executable] + command.arguments
  }
}

struct VerificationCommandResolver: Sendable {
  func resolve(
    _ selection: VerificationCommandSelection,
    commands: [VerificationCommand]
  ) throws -> ResolvedVerificationCommand {
    switch selection {
    case .index(let index):
      guard commands.indices.contains(index) else {
        throw VerificationRunnerError.commandIndexOutOfRange
      }
      return resolved(commands[index], index: index)
    case .identifier(let identifier):
      guard
        let match = commands.enumerated().first(where: {
          VerificationCommandIdentifier(command: $0.element) == identifier
        })
      else {
        throw VerificationRunnerError.unknownCommandIdentifier
      }
      return resolved(match.element, index: match.offset)
    }
  }

  private func resolved(_ command: VerificationCommand, index: Int) -> ResolvedVerificationCommand {
    ResolvedVerificationCommand(
      index: index,
      identifier: VerificationCommandIdentifier(command: command),
      command: command
    )
  }
}
