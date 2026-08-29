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
    guard let modelID else { return nil }
    let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else { return nil }
    let resolvedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let model: String
    if let resolvedName, !resolvedName.isEmpty {
      model = resolvedName
    } else {
      model =
        identifier == "provider-default"
        ? "Provider 默认（未报告具体模型）"
        : identifier
    }
    guard let effort else { return model }
    let normalizedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedEffort.isEmpty, normalizedEffort != "provider-default" else { return model }
    return "\(model) · \(normalizedEffort.prefix(1).uppercased())\(normalizedEffort.dropFirst())"
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
