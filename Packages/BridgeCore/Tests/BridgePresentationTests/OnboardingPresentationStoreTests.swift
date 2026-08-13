import XCTest

@testable import BridgePresentation

@MainActor
final class OnboardingPresentationStoreTests: XCTestCase {
  func testRenderAndSuccessfulActionKeepInfrastructureStateOutsideStore() async {
    let handler = OnboardingActionRecorder()
    let store = OnboardingPresentationStore(actionHandler: handler)
    let ready = onboardingPresentation(step: .connectionMode)

    store.render(ready)
    let succeeded = await store.perform(.selectConnectionMode(.localDevelopment))
    let actions = await handler.actions()

    XCTAssertTrue(succeeded)
    XCTAssertEqual(store.presentation, ready)
    XCTAssertEqual(actions, [.selectConnectionMode(.localDevelopment)])
    XCTAssertNil(store.actionError)
  }

  func testFailedActionSurfacesBoundedErrorWithoutAdvancingPresentation() async {
    let handler = OnboardingActionRecorder(error: OnboardingActionFailure())
    let initial = onboardingPresentation(step: .connectionTest)
    let store = OnboardingPresentationStore(presentation: initial, actionHandler: handler)

    let succeeded = await store.perform(.testConnection)

    XCTAssertFalse(succeeded)
    XCTAssertEqual(store.presentation, initial)
    XCTAssertEqual(store.actionError?.title, "无法继续")
    XCTAssertEqual(store.actionError?.message, "连接测试未通过")
    store.dismissError()
    XCTAssertNil(store.actionError)
  }
}

private actor OnboardingActionRecorder: OnboardingActionHandling {
  private var values: [OnboardingAction] = []
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  func handle(_ action: OnboardingAction) throws {
    values.append(action)
    if let error { throw error }
  }

  func actions() -> [OnboardingAction] {
    values
  }
}

private struct OnboardingActionFailure: LocalizedError {
  var errorDescription: String? { "连接测试未通过" }
}

private func onboardingPresentation(step: OnboardingStep) -> OnboardingPresentation {
  OnboardingPresentation(
    currentStep: step,
    account: OnboardingAccountPresentation(
      status: .ready,
      title: "ChatGPT 登录已就绪",
      detail: "官方账号状态已确认。"
    ),
    connectionStatus: OnboardingCheckPresentation(
      id: "connection",
      title: "连接尚未测试",
      detail: "等待真实传输自检。",
      status: .pending
    ),
    canContinue: true,
    canGoBack: true
  )
}
