#if os(Windows)
  import Foundation
  import WinSDK

  final class WindowsChatWebView: @unchecked Sendable {
    enum State: Equatable {
      case unsupported
      case loading
      case active
      case failed
    }

    static let chatURL = "https://chatgpt.com"

    private let lock = NSLock()
    private var snapshot = Snapshot(state: .loading, errorDetail: nil)
    private var worker: WindowsWebViewThread?

    var state: State {
      lock.withLock { snapshot.state }
    }

    var errorDetail: String? {
      lock.withLock { snapshot.errorDetail }
    }

    func attach(to window: HWND?) {
      guard let window else { return }
      let next = WindowsWebViewThread(parentWindow: window) { [weak self] state, detail in
        self?.store(state: state, errorDetail: detail)
      }
      guard
        lock.withLock({
          guard worker == nil else { return false }
          worker = next
          return true
        })
      else { return }
      next.start()
    }

    func resize(to bounds: RECT) {
      lock.withLock { worker }?.resize(to: bounds)
    }

    func setVisible(_ visible: Bool) {
      lock.withLock { worker }?.setVisible(visible)
    }

    func goBack() {
      lock.withLock { worker }?.goBack()
    }

    func goForward() {
      lock.withLock { worker }?.goForward()
    }

    func reload() {
      lock.withLock { worker }?.reload()
    }

    func shutdown() {
      let active = lock.withLock { () -> WindowsWebViewThread? in
        defer { worker = nil }
        return worker
      }
      active?.shutdown()
    }

    private func store(state: State, errorDetail: String?) {
      lock.withLock {
        snapshot = Snapshot(state: state, errorDetail: errorDetail)
      }
    }

    private struct Snapshot {
      let state: State
      let errorDetail: String?
    }
  }
#endif
