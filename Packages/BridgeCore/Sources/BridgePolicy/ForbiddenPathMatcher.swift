import BridgeProjects
import BridgeSecurity

enum ForbiddenPathMatcher {
  static func matches(_ pattern: ForbiddenPathPattern, path: SecureRelativePath) -> Bool {
    let patternComponents = pattern.value.lowercased().split(separator: "/").map(String.init)
    let pathComponents = path.components.map { $0.lowercased() }
    var reachable = Array(
      repeating: Array(repeating: false, count: pathComponents.count + 1),
      count: patternComponents.count + 1
    )
    reachable[0][0] = true

    for patternIndex in patternComponents.indices {
      for pathIndex in 0...pathComponents.count where reachable[patternIndex][pathIndex] {
        let component = patternComponents[patternIndex]
        if component == "**" {
          reachable[patternIndex + 1][pathIndex] = true
          if pathIndex < pathComponents.count {
            reachable[patternIndex][pathIndex + 1] = true
          }
        } else if pathIndex < pathComponents.count,
          componentMatches(component, value: pathComponents[pathIndex])
        {
          reachable[patternIndex + 1][pathIndex + 1] = true
        }
      }
    }
    return reachable[patternComponents.count][pathComponents.count]
  }

  private static func componentMatches(_ pattern: String, value: String) -> Bool {
    let pattern = Array(pattern)
    let value = Array(value)
    var reachable = Array(
      repeating: Array(repeating: false, count: value.count + 1),
      count: pattern.count + 1
    )
    reachable[0][0] = true

    for patternIndex in pattern.indices {
      for valueIndex in 0...value.count where reachable[patternIndex][valueIndex] {
        switch pattern[patternIndex] {
        case "*":
          reachable[patternIndex + 1][valueIndex] = true
          if valueIndex < value.count {
            reachable[patternIndex][valueIndex + 1] = true
          }
        case "?" where valueIndex < value.count:
          reachable[patternIndex + 1][valueIndex + 1] = true
        default:
          if valueIndex < value.count, pattern[patternIndex] == value[valueIndex] {
            reachable[patternIndex + 1][valueIndex + 1] = true
          }
        }
      }
    }
    return reachable[pattern.count][value.count]
  }
}
