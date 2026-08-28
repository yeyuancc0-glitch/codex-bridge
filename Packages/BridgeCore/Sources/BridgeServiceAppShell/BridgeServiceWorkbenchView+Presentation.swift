package enum WorkbenchApprovalPresentation {
  package static func shouldReveal(previous: [String], current: [String]) -> Bool {
    guard !current.isEmpty else { return false }
    return !Set(current).isSubset(of: Set(previous))
  }
}

package enum WorkbenchThreadTitlePresentation {
  package static func compact(_ value: String, maximumCharacters: Int) -> String {
    precondition(maximumCharacters >= 2)
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return "未命名会话" }
    guard normalized.count > maximumCharacters else { return normalized }
    return String(normalized.prefix(maximumCharacters - 1)) + "…"
  }
}

package enum WorkbenchTaskModelPresentation {
  package static func label(
    modelID: String?,
    effort: String?,
    displayName: String?
  ) -> String? {
    guard let modelID, !modelID.isEmpty, let effort, !effort.isEmpty else { return nil }
    let model = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? modelID
    return "\(model) · \(effort.prefix(1).uppercased())\(effort.dropFirst())"
  }
}

package enum WorkbenchAgentPermissionPresentation {
  package static func title(_ value: String?) -> String {
    switch value {
    case "workspace-write": "Build（工作区可写）"
    case "read-only": "Plan（只读）"
    case let value? where !value.isEmpty: "权限：\(value)"
    default: "权限未记录"
    }
  }
}
