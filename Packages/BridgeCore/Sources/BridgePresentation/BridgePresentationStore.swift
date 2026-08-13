import Foundation
import SwiftUI

@MainActor
public final class BridgePresentationStore: ObservableObject {
  @Published public private(set) var snapshot: BridgePresentationSnapshot
  @Published public var destination: BridgeNavigationDestination
  @Published public var selectedTaskID: String?
  @Published public var selectedProjectID: String?
  @Published public var selectedTaskEvidenceTab: TaskEvidenceTab
  @Published public private(set) var presentedSheet: PresentedBridgeSheet?
  @Published public private(set) var isPerformingSheetAction = false
  @Published public var actionError: PresentationErrorState?

  private let actionHandler: any BridgePresentationActionHandling

  public init(
    snapshot: BridgePresentationSnapshot = .loading,
    destination: BridgeNavigationDestination = .overview,
    actionHandler: any BridgePresentationActionHandling
  ) {
    self.snapshot = snapshot
    self.destination = destination
    self.actionHandler = actionHandler
    self.selectedTaskEvidenceTab = .summary
    reconcileSelections(with: snapshot)
  }

  public func render(_ snapshot: BridgePresentationSnapshot) {
    self.snapshot = snapshot
    reconcileSelections(with: snapshot)
  }

  @discardableResult
  public func perform(_ action: PresentationAction) async -> Bool {
    do {
      try await actionHandler.handle(action)
      return true
    } catch {
      actionError = PresentationErrorState(
        title: "操作未完成",
        message: error.localizedDescription
      )
      return false
    }
  }

  public func selectTask(_ id: String?) {
    selectedTaskID = id
    selectedTaskEvidenceTab = .summary
  }

  public func selectProject(_ id: String?) {
    selectedProjectID = id
  }

  public func presentTaskConfirmation(_ confirmation: TaskConfirmationPresentation) {
    presentedSheet = .taskConfirmation(confirmation)
  }

  public func presentCodexApproval(_ approval: CodexApprovalPresentation) {
    presentedSheet = .codexApproval(approval)
  }

  public func dismissSheet() {
    guard !isPerformingSheetAction else { return }
    presentedSheet = nil
  }

  public func updateConfirmationModel(_ model: String) {
    guard case .taskConfirmation(var confirmation) = presentedSheet else { return }
    guard confirmation.availableModels.contains(model) else { return }
    confirmation.executionModel = model
    presentedSheet = .taskConfirmation(confirmation)
  }

  public func updateConfirmationEffort(_ effort: String) {
    guard case .taskConfirmation(var confirmation) = presentedSheet else { return }
    guard confirmation.availableEfforts.contains(effort) else { return }
    confirmation.effort = effort
    presentedSheet = .taskConfirmation(confirmation)
  }

  public func decideTask(_ decision: PresentationTaskDecision) async {
    guard case .taskConfirmation(let confirmation) = presentedSheet else { return }
    if decision != .reject {
      let hasModel = confirmation.availableModels.contains(confirmation.executionModel)
      let hasEffort = confirmation.availableEfforts.contains(confirmation.effort)
      guard hasModel && hasEffort else { return }
    }
    isPerformingSheetAction = true
    let succeeded = await perform(
      .decideTask(
        requestID: confirmation.id,
        decision: decision,
        model: confirmation.executionModel,
        effort: confirmation.effort
      )
    )
    isPerformingSheetAction = false
    if succeeded { presentedSheet = nil }
  }

  public func decideApproval(_ decision: PresentationApprovalDecision) async {
    guard case .codexApproval(let approval) = presentedSheet else { return }
    guard decision == .deny || approval.canAllow else { return }
    isPerformingSheetAction = true
    let succeeded = await perform(.decideApproval(approvalID: approval.id, decision: decision))
    isPerformingSheetAction = false
    if succeeded { presentedSheet = nil }
  }

  private func reconcileSelections(with snapshot: BridgePresentationSnapshot) {
    selectedTaskID = reconciledTaskID(in: snapshot.tasks)
    selectedProjectID = reconciledProjectID(in: snapshot.projects)
  }

  private func reconciledTaskID(
    in state: PresentationLoadState<TaskPagePresentation>
  ) -> String? {
    guard case .ready(let page) = state else { return nil }
    if let selectedTaskID, page.tasks.contains(where: { $0.id == selectedTaskID }) {
      return selectedTaskID
    }
    return page.tasks.first?.id
  }

  private func reconciledProjectID(
    in state: PresentationLoadState<ProjectPagePresentation>
  ) -> String? {
    guard case .ready(let page) = state else { return nil }
    if let selectedProjectID, page.projects.contains(where: { $0.id == selectedProjectID }) {
      return selectedProjectID
    }
    return page.projects.first?.id
  }
}

public enum TaskEvidenceTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case summary
  case timeline
  case commands
  case files
  case diff
  case supervision
  case verification
  case logs

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .summary: "概览"
    case .timeline: "时间线"
    case .commands: "命令"
    case .files: "文件"
    case .diff: "Diff"
    case .supervision: "监督"
    case .verification: "验证"
    case .logs: "日志"
    }
  }
}
