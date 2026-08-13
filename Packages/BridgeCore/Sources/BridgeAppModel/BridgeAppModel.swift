import BridgePresentation
import Combine
import Foundation

public enum BridgeAppLifecycleState: Equatable, Sendable {
  case stopped
  case starting
  case running(revision: UInt64, connection: BridgeAppConnectionState)
  case failed
}

@MainActor
public final class BridgeAppModel: ObservableObject {
  @Published public private(set) var lifecycleState: BridgeAppLifecycleState = .stopped
  public let presentationStore: BridgePresentationStore

  private let backend: any BridgeAppBackend
  private let router: BridgeAppActionRouter
  private var subscription: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var activeGeneration: UInt64?
  private var lastRevision: UInt64?

  public init(backend: any BridgeAppBackend) {
    self.backend = backend
    let router = BridgeAppActionRouter(backend: backend)
    self.router = router
    self.presentationStore = BridgePresentationStore(actionHandler: router)
  }

  deinit {
    subscription?.cancel()
  }

  public func start() {
    guard subscription == nil else { return }
    generation &+= 1
    let currentGeneration = generation
    activeGeneration = currentGeneration
    lifecycleState = .starting
    subscription = Task { [weak self, backend] in
      let updates = await backend.stateUpdates()
      do {
        for try await snapshot in updates {
          try Task.checkCancellation()
          await self?.consume(snapshot, generation: currentGeneration)
        }
        try Task.checkCancellation()
        await self?.endStream(generation: currentGeneration)
      } catch is CancellationError {
        return
      } catch {
        await self?.failStream(generation: currentGeneration)
      }
    }
  }

  public func stop() async {
    subscription?.cancel()
    subscription = nil
    activeGeneration = nil
    lastRevision = nil
    await router.reset()
    presentationStore.dismissSheet()
    lifecycleState = .stopped
  }

  public func submit(_ submission: BridgeAppTaskSubmission) async throws -> BridgeAppTaskReceipt {
    try await router.submit(submission)
  }

  public func steer(_ request: BridgeAppSteerRequest) async throws {
    try await router.steer(request)
  }

  public func connect() async throws {
    try await router.connect()
  }

  public func disconnect() async throws {
    try await router.disconnect()
  }

  private func consume(
    _ snapshot: BridgeAppStateSnapshot,
    generation: UInt64
  ) async {
    guard activeGeneration == generation else { return }
    if let lastRevision, snapshot.revision <= lastRevision { return }
    let capabilityIDs = Set(snapshot.approvalCapabilities.map(\.approvalID))
    guard capabilityIDs.count == snapshot.approvalCapabilities.count else {
      subscription?.cancel()
      await failStream(generation: generation)
      return
    }
    let authorizedCapabilities = FailClosedPresentationProjection.authorizedCapabilities(
      presentation: snapshot.presentation,
      sheet: snapshot.pendingSheet,
      capabilities: snapshot.approvalCapabilities
    )
    do {
      try await router.install(
        capabilities: authorizedCapabilities,
        revision: snapshot.revision
      )
    } catch {
      subscription?.cancel()
      await failStream(generation: generation)
      return
    }
    lastRevision = snapshot.revision
    let presentation = FailClosedPresentationProjection.snapshot(
      snapshot.presentation,
      capabilities: snapshot.approvalCapabilities
    )
    presentationStore.render(presentation)
    synchronizeSheet(
      FailClosedPresentationProjection.sheet(
        snapshot.pendingSheet,
        capabilities: snapshot.approvalCapabilities
      )
    )
    lifecycleState = .running(
      revision: snapshot.revision,
      connection: snapshot.connectionState
    )
  }

  private func synchronizeSheet(_ sheet: PresentedBridgeSheet?) {
    guard let sheet else {
      presentationStore.dismissSheet()
      return
    }
    switch sheet {
    case .taskConfirmation(let confirmation):
      presentationStore.presentTaskConfirmation(confirmation)
    case .codexApproval(let approval):
      presentationStore.presentCodexApproval(approval)
    }
  }

  private func endStream(generation: UInt64) async {
    guard activeGeneration == generation else { return }
    await failStream(generation: generation)
  }

  private func failStream(generation: UInt64) async {
    guard activeGeneration == generation else { return }
    subscription = nil
    activeGeneration = nil
    lastRevision = nil
    await router.reset()
    presentationStore.dismissSheet()
    presentationStore.render(FailClosedPresentationProjection.synchronizationFailure())
    lifecycleState = .failed
  }
}
