import Foundation

public enum CodexApprovalWireError: Error, Equatable, Sendable {
  case unsupportedRequestMethod(String)
  case unsupportedItemType(String)
  case missingField(String)
  case invalidField(String)
  case unknownField(context: String, field: String)
  case unknownDiscriminator(field: String, value: String)
  case stringTooLarge(field: String, maximumBytes: Int)
  case arrayTooLarge(field: String, maximumCount: Int)
  case evidenceTooLarge(maximumBytes: Int)
}

public enum CodexApprovalWireLimits {
  public static let identifierBytes = 256
  public static let stringBytes = 4 * 1024
  public static let commandBytes = 64 * 1024
  public static let arrayCount = 256
  public static let diffBytes = 256 * 1024
  public static let totalEvidenceBytes = 512 * 1024
}

public struct CodexApprovalItemKey: Equatable, Hashable, Sendable {
  public let threadID: String
  public let turnID: String
  public let itemID: String

  public init(threadID: String, turnID: String, itemID: String) {
    self.threadID = threadID
    self.turnID = turnID
    self.itemID = itemID
  }
}

public struct CodexApprovalCorrelation: Equatable, Sendable {
  public let requestID: RequestID
  public let item: CodexApprovalItemKey
  public let callbackID: String?
  public let startedAtMilliseconds: Int64
}

public enum CodexCommandAction: Equatable, Sendable {
  case read(displayCommand: String, name: String, path: String)
  case listFiles(displayCommand: String, path: String?)
  case search(displayCommand: String, path: String?, query: String?)
  case unknown(displayCommand: String)
}

public enum CodexNetworkApprovalProtocol: String, Equatable, Sendable {
  case http
  case https
  case socks5TCP = "socks5Tcp"
  case socks5UDP = "socks5Udp"
}

public struct CodexNetworkApprovalContext: Equatable, Sendable {
  public let host: String
  public let `protocol`: CodexNetworkApprovalProtocol
}

public enum CodexNetworkPolicyAction: String, Equatable, Sendable {
  case allow
  case deny
}

public struct CodexNetworkPolicyAmendment: Equatable, Sendable {
  public let action: CodexNetworkPolicyAction
  public let host: String
}

public struct CodexCommandApprovalRequest: Equatable, Sendable {
  public let correlation: CodexApprovalCorrelation
  public let displayCommand: String?
  public let displayWorkingDirectory: String?
  public let displayActions: [CodexCommandAction]?
  public let reason: String?
  public let environmentID: String?
  public let networkContext: CodexNetworkApprovalContext?
  public let proposedExecPolicyAmendment: [String]?
  public let proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]?
}

public struct CodexFileChangeApprovalRequest: Equatable, Sendable {
  public let correlation: CodexApprovalCorrelation
  public let grantRoot: String?
  public let reason: String?
}

public enum CodexFileSystemAccess: String, Equatable, Sendable {
  case read
  case write
  case deny
}

public enum CodexSpecialFileSystemPath: Equatable, Sendable {
  case root
  case minimal
  case projectRoots(subpath: String?)
  case temporaryDirectory
  case slashTemporaryDirectory
  case unknown(path: String, subpath: String?)
}

public enum CodexFileSystemPath: Equatable, Sendable {
  case path(String)
  case globPattern(String)
  case special(CodexSpecialFileSystemPath)
}

public struct CodexFileSystemPermissionEntry: Equatable, Sendable {
  public let access: CodexFileSystemAccess
  public let path: CodexFileSystemPath
}

public struct CodexAdditionalFileSystemPermissions: Equatable, Sendable {
  public let entries: [CodexFileSystemPermissionEntry]?
  public let globScanMaximumDepth: UInt?
  public let legacyReadPaths: [String]?
  public let legacyWritePaths: [String]?
}

public struct CodexAdditionalNetworkPermissions: Equatable, Sendable {
  public let enabled: Bool?
}

public struct CodexRequestPermissionProfile: Equatable, Sendable {
  public let fileSystem: CodexAdditionalFileSystemPermissions?
  public let network: CodexAdditionalNetworkPermissions?
}

public struct CodexPermissionsApprovalRequest: Equatable, Sendable {
  public let correlation: CodexApprovalCorrelation
  public let workingDirectory: String
  public let permissions: CodexRequestPermissionProfile
  public let reason: String?
  public let environmentID: String?
}

public enum CodexApprovalRequest: Equatable, Sendable {
  case command(CodexCommandApprovalRequest)
  case fileChange(CodexFileChangeApprovalRequest)
  case permissions(CodexPermissionsApprovalRequest)

  public var correlation: CodexApprovalCorrelation {
    switch self {
    case .command(let request): request.correlation
    case .fileChange(let request): request.correlation
    case .permissions(let request): request.correlation
    }
  }
}

public enum CodexCommandExecutionStatus: String, Equatable, Sendable {
  case inProgress
  case completed
  case failed
  case declined
}

public struct CodexCommandExecutionEvidence: Equatable, Sendable {
  public let item: CodexApprovalItemKey
  public let startedAtMilliseconds: Int64
  public let displayCommand: String
  public let workingDirectory: String
  public let displayActions: [CodexCommandAction]
  public let status: CodexCommandExecutionStatus
}

public enum CodexFileChangeKind: Equatable, Sendable {
  case add
  case delete
  case update(movePath: String?)
}

public struct CodexFileUpdateEvidence: Equatable, Sendable {
  public let path: String
  public let diff: String
  public let kind: CodexFileChangeKind
}

public enum CodexFileChangeStatus: String, Equatable, Sendable {
  case inProgress
  case completed
  case failed
  case declined
}

public struct CodexFileChangeEvidence: Equatable, Sendable {
  public let item: CodexApprovalItemKey
  public let startedAtMilliseconds: Int64
  public let changes: [CodexFileUpdateEvidence]
  public let status: CodexFileChangeStatus
}

public enum CodexApprovalItemEvidence: Equatable, Sendable {
  case commandExecution(CodexCommandExecutionEvidence)
  case fileChange(CodexFileChangeEvidence)

  public var item: CodexApprovalItemKey {
    switch self {
    case .commandExecution(let evidence): evidence.item
    case .fileChange(let evidence): evidence.item
    }
  }
}
