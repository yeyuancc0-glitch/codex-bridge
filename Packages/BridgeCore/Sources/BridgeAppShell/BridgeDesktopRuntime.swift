import BridgeAppModel
import BridgePresentation
import BridgeSecurity
import Foundation

@MainActor
public final class BridgeDesktopRuntime: ObservableObject {
  public let appModel: BridgeAppModel
  public let onboardingStore: OnboardingPresentationStore
  @Published public private(set) var onboardingFinished = false

  private let backend: LiveBridgeAppBackend
  private let onboardingService: DesktopOnboardingService
  private let system: any DesktopSystemServing
  private var onboardingSubscription: Task<Void, Never>?
  private var started = false
  private var stopped = false

  public convenience init() {
    self.init(
      dataDirectoryURL: Self.defaultDataDirectoryURL(),
      system: AppKitDesktopSystemService()
    )
  }

  init(dataDirectoryURL: URL, system: any DesktopSystemServing) {
    let secretStore = KeychainSecretStore()
    let backend = LiveBridgeAppBackend(
      dataDirectoryURL: dataDirectoryURL,
      system: system,
      secretStore: secretStore
    )
    let onboardingService = DesktopOnboardingService(
      dataDirectoryURL: dataDirectoryURL,
      backend: backend,
      system: system,
      secretStore: secretStore
    )
    self.backend = backend
    self.onboardingService = onboardingService
    self.system = system
    appModel = BridgeAppModel(backend: backend)
    onboardingStore = OnboardingPresentationStore(actionHandler: onboardingService)
  }

  public func start() {
    guard !started, !stopped else { return }
    started = true
    appModel.start()
    onboardingSubscription = Task { [weak self, onboardingService] in
      let updates = await onboardingService.stateUpdates()
      for await presentation in updates {
        guard !Task.isCancelled else { return }
        self?.onboardingStore.render(presentation)
        self?.onboardingFinished = presentation.isFinished
      }
    }
  }

  public func shutdown() async {
    guard !stopped else { return }
    stopped = true
    onboardingSubscription?.cancel()
    onboardingSubscription = nil
    await onboardingService.shutdown()
    await appModel.stop()
    await backend.shutdown()
  }

  public func showMainWindow() {
    system.showMainWindow()
  }

  public func openTaskFromNotification(_ taskID: String) {
    presentationStore.openTaskRoute(taskID)
    showMainWindow()
  }

  public func terminateApplication() {
    system.terminateApplication()
  }

  public var presentationStore: BridgePresentationStore {
    appModel.presentationStore
  }

  private static func defaultDataDirectoryURL() -> URL {
    let fileManager = FileManager.default
    let parent =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    return parent.appendingPathComponent("CodexBridge", isDirectory: true)
  }
}
