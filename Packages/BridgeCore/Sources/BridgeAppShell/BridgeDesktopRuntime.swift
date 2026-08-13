import BridgeAppModel
import BridgePresentation
import Foundation

@MainActor
public final class BridgeDesktopRuntime: ObservableObject {
  public let appModel: BridgeAppModel

  private let backend: LiveBridgeAppBackend
  private let system: any DesktopSystemServing
  private var started = false
  private var stopped = false

  public convenience init() {
    self.init(
      dataDirectoryURL: Self.defaultDataDirectoryURL(),
      system: AppKitDesktopSystemService()
    )
  }

  init(dataDirectoryURL: URL, system: any DesktopSystemServing) {
    let backend = LiveBridgeAppBackend(dataDirectoryURL: dataDirectoryURL, system: system)
    self.backend = backend
    self.system = system
    appModel = BridgeAppModel(backend: backend)
  }

  public func start() {
    guard !started, !stopped else { return }
    started = true
    appModel.start()
  }

  public func shutdown() async {
    guard !stopped else { return }
    stopped = true
    await appModel.stop()
    await backend.shutdown()
  }

  public func showMainWindow() {
    system.showMainWindow()
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
