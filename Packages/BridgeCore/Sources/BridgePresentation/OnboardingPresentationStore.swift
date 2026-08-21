import Foundation
import SwiftUI

@MainActor
public final class OnboardingPresentationStore: ObservableObject {
  @Published public private(set) var presentation: OnboardingPresentation
  @Published public private(set) var actionError: PresentationErrorState?

  private let actionHandler: any OnboardingActionHandling

  public init(
    presentation: OnboardingPresentation = .loading,
    actionHandler: any OnboardingActionHandling
  ) {
    self.presentation = presentation
    self.actionHandler = actionHandler
  }

  public func render(_ presentation: OnboardingPresentation) {
    self.presentation = presentation
  }

  public func perform(_ action: OnboardingAction) async -> Bool {
    do {
      try await actionHandler.handle(action)
      return true
    } catch {
      actionError = PresentationErrorState(
        title: "无法继续",
        message: error.localizedDescription
      )
      return false
    }
  }

  public func dismissError() {
    actionError = nil
  }
}
