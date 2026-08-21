import Foundation

public protocol BridgeStringIdentifier: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {}

public struct TaskID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ProjectID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ThreadID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TurnID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ApprovalID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct OperationID: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct IdempotencyKey: BridgeStringIdentifier {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}
