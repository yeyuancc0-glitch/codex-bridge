import Foundation

extension CodexApprovalWireDecoder {
  static func permissionProfile(_ value: JSONValue?) throws -> CodexRequestPermissionProfile {
    let object = try object(value, field: "permissions")
    try requireOnlyKeys(object, allowed: ["fileSystem", "network"], context: "permissions")
    return CodexRequestPermissionProfile(
      fileSystem: try optionalFileSystemPermissions(object["fileSystem"]),
      network: try optionalNetworkPermissions(object["network"])
    )
  }

  static func optionalFileSystemPermissions(
    _ value: JSONValue?
  ) throws -> CodexAdditionalFileSystemPermissions? {
    guard value != nil, value != .null else { return nil }
    let object = try object(value, field: "permissions.fileSystem")
    try requireOnlyKeys(
      object,
      allowed: ["entries", "globScanMaxDepth", "read", "write"],
      context: "permissions.fileSystem"
    )
    let depth = try optionalUnsignedInteger(object, key: "globScanMaxDepth")
    if let depth, depth < 1 { throw CodexApprovalWireError.invalidField("globScanMaxDepth") }
    return CodexAdditionalFileSystemPermissions(
      entries: try optionalPermissionEntries(object["entries"]),
      globScanMaximumDepth: depth,
      legacyReadPaths: try optionalStringArray(
        object["read"], field: "permissions.fileSystem.read"),
      legacyWritePaths: try optionalStringArray(
        object["write"], field: "permissions.fileSystem.write")
    )
  }

  static func optionalNetworkPermissions(
    _ value: JSONValue?
  ) throws -> CodexAdditionalNetworkPermissions? {
    guard value != nil, value != .null else { return nil }
    let object = try object(value, field: "permissions.network")
    try requireOnlyKeys(object, allowed: ["enabled"], context: "permissions.network")
    return CodexAdditionalNetworkPermissions(enabled: try optionalBool(object, key: "enabled"))
  }

  static func optionalPermissionEntries(
    _ value: JSONValue?
  ) throws -> [CodexFileSystemPermissionEntry]? {
    guard value != nil, value != .null else { return nil }
    let values = try array(value, field: "permissions.fileSystem.entries")
    try validateArray(values, field: "permissions.fileSystem.entries")
    return try values.enumerated().map { index, value in
      let field = "permissions.fileSystem.entries[\(index)]"
      let object = try object(value, field: field)
      try requireOnlyKeys(object, allowed: ["access", "path"], context: field)
      let rawAccess = try requiredString(object, key: "access", maximumBytes: 16)
      guard let access = CodexFileSystemAccess(rawValue: rawAccess) else {
        throw CodexApprovalWireError.unknownDiscriminator(
          field: "\(field).access", value: rawAccess)
      }
      return CodexFileSystemPermissionEntry(
        access: access,
        path: try fileSystemPath(object["path"], field: "\(field).path"))
    }
  }

  static func fileSystemPath(
    _ value: JSONValue?,
    field: String
  ) throws -> CodexFileSystemPath {
    let object = try object(value, field: field)
    let type = try requiredString(object, key: "type", maximumBytes: 32)
    switch type {
    case "path":
      try requireOnlyKeys(object, allowed: ["type", "path"], context: field)
      return .path(try requiredString(object, key: "path"))
    case "glob_pattern":
      try requireOnlyKeys(object, allowed: ["type", "pattern"], context: field)
      return .globPattern(try requiredString(object, key: "pattern"))
    case "special":
      try requireOnlyKeys(object, allowed: ["type", "value"], context: field)
      return .special(try specialFileSystemPath(object["value"], field: "\(field).value"))
    default:
      throw CodexApprovalWireError.unknownDiscriminator(field: "\(field).type", value: type)
    }
  }

  static func specialFileSystemPath(
    _ value: JSONValue?,
    field: String
  ) throws -> CodexSpecialFileSystemPath {
    let object = try object(value, field: field)
    let kind = try requiredString(object, key: "kind", maximumBytes: 32)
    switch kind {
    case "root":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .root
    case "minimal":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .minimal
    case "project_roots":
      try requireOnlyKeys(object, allowed: ["kind", "subpath"], context: field)
      return .projectRoots(subpath: try optionalString(object, key: "subpath"))
    case "tmpdir":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .temporaryDirectory
    case "slash_tmp":
      try requireOnlyKeys(object, allowed: ["kind"], context: field)
      return .slashTemporaryDirectory
    case "unknown":
      try requireOnlyKeys(object, allowed: ["kind", "path", "subpath"], context: field)
      return .unknown(
        path: try requiredString(object, key: "path"),
        subpath: try optionalString(object, key: "subpath"))
    default:
      throw CodexApprovalWireError.unknownDiscriminator(field: "\(field).kind", value: kind)
    }
  }
}
