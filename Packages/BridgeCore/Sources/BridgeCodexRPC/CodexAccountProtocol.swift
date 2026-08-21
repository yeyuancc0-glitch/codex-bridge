import Foundation

public struct CodexAccount: Codable, Equatable, Sendable {
  public let type: String
  public let email: String?
  public let planType: String?
  public let usesCodexManagedCredentials: Bool?

  public init(
    type: String,
    email: String? = nil,
    planType: String? = nil,
    usesCodexManagedCredentials: Bool? = nil
  ) {
    self.type = type
    self.email = email
    self.planType = planType
    self.usesCodexManagedCredentials = usesCodexManagedCredentials
  }
}

public struct GetAccountParams: Codable, Equatable, Sendable {
  public let refreshToken: Bool

  public init(refreshToken: Bool = false) {
    self.refreshToken = refreshToken
  }
}

public struct GetAccountResponse: Codable, Equatable, Sendable {
  public let account: CodexAccount?
  public let requiresOpenaiAuth: Bool

  public init(account: CodexAccount?, requiresOpenaiAuth: Bool) {
    self.account = account
    self.requiresOpenaiAuth = requiresOpenaiAuth
  }
}

public struct StartChatGPTLoginParams: Codable, Equatable, Sendable {
  public let type: String

  public init() {
    type = "chatgpt"
  }
}

public struct StartChatGPTLoginResponse: Codable, Equatable, Sendable {
  public let type: String
  public let loginId: String?
  public let authUrl: String?
  public let userCode: String?
  public let verificationUrl: String?

  public init(
    type: String,
    loginId: String? = nil,
    authUrl: String? = nil,
    userCode: String? = nil,
    verificationUrl: String? = nil
  ) {
    self.type = type
    self.loginId = loginId
    self.authUrl = authUrl
    self.userCode = userCode
    self.verificationUrl = verificationUrl
  }
}

public struct CancelLoginParams: Codable, Equatable, Sendable {
  public let loginId: String

  public init(loginId: String) {
    self.loginId = loginId
  }
}

public struct CancelLoginResponse: Codable, Equatable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

public struct CodexRateLimitWindow: Codable, Equatable, Sendable {
  public let usedPercent: Int
  public let windowDurationMins: Int64?
  public let resetsAt: Int64?

  public init(usedPercent: Int, windowDurationMins: Int64?, resetsAt: Int64?) {
    self.usedPercent = usedPercent
    self.windowDurationMins = windowDurationMins
    self.resetsAt = resetsAt
  }
}

public struct CodexCreditsSnapshot: Codable, Equatable, Sendable {
  public let hasCredits: Bool
  public let unlimited: Bool
  public let balance: String?

  public init(hasCredits: Bool, unlimited: Bool, balance: String?) {
    self.hasCredits = hasCredits
    self.unlimited = unlimited
    self.balance = balance
  }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
  public let limitId: String?
  public let limitName: String?
  public let planType: String?
  public let primary: CodexRateLimitWindow?
  public let secondary: CodexRateLimitWindow?
  public let credits: CodexCreditsSnapshot?
  public let rateLimitReachedType: String?
  public let spendControlReached: Bool?

  public init(
    limitId: String? = nil,
    limitName: String? = nil,
    planType: String? = nil,
    primary: CodexRateLimitWindow? = nil,
    secondary: CodexRateLimitWindow? = nil,
    credits: CodexCreditsSnapshot? = nil,
    rateLimitReachedType: String? = nil,
    spendControlReached: Bool? = nil
  ) {
    self.limitId = limitId
    self.limitName = limitName
    self.planType = planType
    self.primary = primary
    self.secondary = secondary
    self.credits = credits
    self.rateLimitReachedType = rateLimitReachedType
    self.spendControlReached = spendControlReached
  }
}

public struct GetAccountRateLimitsResponse: Codable, Equatable, Sendable {
  public let rateLimits: CodexRateLimitSnapshot
  public let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?

  public init(
    rateLimits: CodexRateLimitSnapshot,
    rateLimitsByLimitId: [String: CodexRateLimitSnapshot]? = nil
  ) {
    self.rateLimits = rateLimits
    self.rateLimitsByLimitId = rateLimitsByLimitId
  }
}

public struct AccountUpdatedNotification: Codable, Equatable, Sendable {
  public let authMode: String?
  public let planType: String?

  public init(authMode: String?, planType: String?) {
    self.authMode = authMode
    self.planType = planType
  }
}

public struct AccountLoginCompletedNotification: Codable, Equatable, Sendable {
  public let success: Bool
  public let loginId: String?
  public let error: String?

  public init(success: Bool, loginId: String?, error: String?) {
    self.success = success
    self.loginId = loginId
    self.error = error
  }
}

public struct AccountRateLimitsUpdatedNotification: Codable, Equatable, Sendable {
  public let rateLimits: CodexRateLimitSnapshot

  public init(rateLimits: CodexRateLimitSnapshot) {
    self.rateLimits = rateLimits
  }
}

public enum CodexAccountNotification: Equatable, Sendable {
  case accountUpdated(AccountUpdatedNotification)
  case loginCompleted(AccountLoginCompletedNotification)
  case rateLimitsUpdated(AccountRateLimitsUpdatedNotification)
  case unknown(RPCNotification)
}

extension RPCNotification {
  public func decodedCodexAccountNotification() throws -> CodexAccountNotification {
    switch method {
    case "account/updated":
      return .accountUpdated(try decodeAccountParams(AccountUpdatedNotification.self))
    case "account/login/completed":
      return .loginCompleted(try decodeAccountParams(AccountLoginCompletedNotification.self))
    case "account/rateLimits/updated":
      return .rateLimitsUpdated(
        try decodeAccountParams(AccountRateLimitsUpdatedNotification.self)
      )
    default:
      return .unknown(self)
    }
  }

  private func decodeAccountParams<Value: Decodable>(_ type: Value.Type) throws -> Value {
    guard let params else {
      throw CodexRPCError.malformedMessage("notification \(method) has no params")
    }
    do {
      return try params.decode(type)
    } catch {
      throw CodexRPCError.malformedMessage(
        "notification \(method) has invalid params: \(error.localizedDescription)"
      )
    }
  }
}
