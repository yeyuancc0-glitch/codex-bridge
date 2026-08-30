import BridgeSecurity
import Foundation

enum SkillActionResolver {
  static func resolve(
    _ actionName: String,
    in manifest: SkillManifest,
    fileManager: FileManager
  ) throws -> SkillScanner.SkillActionLaunch {
    guard let action = manifest.actions.first(where: { $0.name == actionName }) else {
      throw SkillError.actionNotFound
    }
    if let commandPrefix = action.commandPrefix {
      guard let executable = commandPrefix.first,
        let resolvedExecutable = SkillActionInterpreter.resolveInterpreter(executable)
      else { throw SkillError.actionNotRunnable }
      return SkillScanner.SkillActionLaunch(
        action: action,
        argvPrefix: [resolvedExecutable] + commandPrefix.dropFirst()
      )
    }
    let scriptPath = try validatedScriptPath(
      action.scriptPath, in: manifest, fileManager: fileManager)
    if let interpreter = action.interpreter {
      guard let resolvedInterpreter = SkillActionInterpreter.resolveInterpreter(interpreter) else {
        throw SkillError.actionNotRunnable
      }
      return SkillScanner.SkillActionLaunch(
        action: action,
        argvPrefix: [resolvedInterpreter, scriptPath]
      )
    }
    guard
      let shebang = try SkillActionInterpreter.shebangInterpreter(
        of: scriptPath,
        fileManager: fileManager
      )
    else {
      throw SkillError.actionNotRunnable
    }
    return SkillScanner.SkillActionLaunch(
      action: action,
      argvPrefix: [shebang, scriptPath]
    )
  }

  private static func validatedScriptPath(
    _ scriptPath: String,
    in manifest: SkillManifest,
    fileManager: FileManager
  ) throws -> String {
    let relative: SecureRelativePath
    do {
      relative = try SecureRelativePath(scriptPath)
    } catch {
      throw SkillError.pathEscapeDetected
    }
    let root = URL(fileURLWithPath: manifest.rootPath).standardizedFileURL
    let target = root.appendingPathComponent(relative.components.joined(separator: "/"))
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedTarget.hasPrefix(resolvedRoot + "/"),
      fileManager.isReadableFile(atPath: target.path)
    else {
      throw SkillError.pathEscapeDetected
    }
    return resolvedTarget
  }
}
