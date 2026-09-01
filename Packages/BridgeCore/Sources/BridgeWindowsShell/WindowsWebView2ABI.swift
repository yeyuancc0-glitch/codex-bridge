#if os(Windows)
  import Foundation
  import WinSDK

  // IID values from WebView2.h (cross-checked against WebView2 SDK derived
  // bindings: go-webview2, Rust webview2-com, arsd webview.d).
  // IID_IUnknown must stay exact; only these three are ever matched by our
  // QueryInterface. Re-verify against WebView2.h when upgrading the SDK.
  private let iidIUnknown = makeGUID(
    0x0000_0000, 0x0000, 0x0000,
    (0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46)
  )
  private let iidEnvironmentHandler = makeGUID(
    0x4E8A_3389, 0xC9D8, 0x4BD2,
    (0xB6, 0xB5, 0x12, 0x4F, 0xEE, 0x6C, 0xC1, 0x4D)
  )
  private let iidControllerHandler = makeGUID(
    0x6C48_19F3, 0xC9B7, 0x4260,
    (0x81, 0x27, 0xC9, 0xF5, 0xBD, 0xE7, 0xF6, 0x8C)
  )

  private func makeGUID(
    _ data1: UInt32,
    _ data2: UInt16,
    _ data3: UInt16,
    _ data4: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
  ) -> GUID {
    var guid = GUID()
    guid.Data1 = data1
    guid.Data2 = data2
    guid.Data3 = data3
    guid.Data4 = data4
    return guid
  }

  private func sameGUID(_ lhs: GUID, _ rhs: GUID) -> Bool {
    lhs.Data1 == rhs.Data1 && lhs.Data2 == rhs.Data2 && lhs.Data3 == rhs.Data3
      && lhs.Data4.0 == rhs.Data4.0 && lhs.Data4.1 == rhs.Data4.1
      && lhs.Data4.2 == rhs.Data4.2 && lhs.Data4.3 == rhs.Data4.3
      && lhs.Data4.4 == rhs.Data4.4 && lhs.Data4.5 == rhs.Data4.5
      && lhs.Data4.6 == rhs.Data4.6 && lhs.Data4.7 == rhs.Data4.7
  }

  // HRESULT values: the cast-macro definitions are not imported by WinSDK.
  let webview2SOK: HRESULT = 0
  private let webview2EPointer = HRESULT(bitPattern: 0x8000_4003)
  private let webview2ENoInterface = HRESULT(bitPattern: 0x8000_4002)

  /// Vtable slot indices, verified against WebView2.h declaration order:
  /// ICoreWebView2Environment.CreateCoreWebView2Controller = 3,
  /// ICoreWebView2Controller.put_Bounds = 6, get_CoreWebView2 = 25,
  /// ICoreWebView2.Navigate = 5.
  enum WebView2Slot {
    static let environmentCreateController = 3
    static let controllerPutIsVisible = 4
    static let controllerPutBounds = 6
    static let controllerGetCoreWebView2 = 25
    static let webViewNavigate = 5
    static let webViewReload = 31
    static let webViewGoBack = 40
    static let webViewGoForward = 41
  }

  /// `CreateCoreWebView2EnvironmentWithOptions` from WebView2Loader.dll.
  typealias WebView2CreateEnvironmentFn =
    @convention(c) (
      UnsafePointer<WCHAR>?,
      UnsafePointer<WCHAR>?,
      UnsafeMutableRawPointer?,
      UnsafeMutableRawPointer?
    ) -> HRESULT

  typealias WebView2CreateControllerFn =
    @convention(c) (
      UnsafeMutableRawPointer?,
      HWND,
      UnsafeMutableRawPointer?
    ) -> HRESULT

  typealias WebView2PutBoundsFn =
    @convention(c) (
      UnsafeMutableRawPointer?,
      RECT
    ) -> HRESULT

  typealias WebView2PutBoolFn =
    @convention(c) (
      UnsafeMutableRawPointer?,
      Bool
    ) -> HRESULT

  typealias WebView2GetCoreWebView2Fn =
    @convention(c) (
      UnsafeMutableRawPointer?,
      UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> HRESULT

  typealias WebView2NavigateFn =
    @convention(c) (
      UnsafeMutableRawPointer?,
      UnsafePointer<WCHAR>?
    ) -> HRESULT

  typealias WebView2ActionFn =
    @convention(c) (
      UnsafeMutableRawPointer?
    ) -> HRESULT

  /// Loads a member function pointer of a COM interface by vtable slot.
  func webView2Method<F>(_ object: UnsafeMutableRawPointer, _ slot: Int, as type: F.Type) -> F {
    let vtable = UnsafeRawPointer(object).load(as: UnsafeRawPointer.self)
    return vtable.load(fromByteOffset: slot * MemoryLayout<UnsafeRawPointer>.size, as: F.self)
  }

  typealias WebView2UnknownFn =
    @convention(c) (
      UnsafeMutableRawPointer?
    ) -> UInt32

  func webView2AddRef(_ object: UnsafeMutableRawPointer) {
    let addRef: WebView2UnknownFn = webView2Method(object, 1, as: WebView2UnknownFn.self)
    _ = addRef(object)
  }

  /// Returns true when the object was freed (refcount reached zero).
  func webView2Release(_ object: UnsafeMutableRawPointer) -> Bool {
    let release: WebView2UnknownFn = webView2Method(object, 2, as: WebView2UnknownFn.self)
    return release(object) == 0
  }

  // MARK: - Completion handler COM objects
  //
  // Both WebView2 completion handlers share one Invoke signature
  // (HRESULT, interface*) and therefore one vtable. Layout is the classic COM
  // object: [vtable pointer][refcount][context]. Refcounts are non-atomic:
  // WebView2 invokes handlers on the thread that started the operation, which
  // is the shell's message-loop thread.

  private struct CompletionHandlerObject {
    var vtable: UnsafeMutablePointer<CompletionHandlerVTable>
    var refCount: UInt32
    var context: Unmanaged<CompletionHandlerContext>
  }

  final class CompletionHandlerContext {
    let onCompleted: (HRESULT, UnsafeMutableRawPointer?) -> Void

    init(onCompleted: @escaping (HRESULT, UnsafeMutableRawPointer?) -> Void) {
      self.onCompleted = onCompleted
    }
  }

  private struct CompletionHandlerVTable {
    var queryInterface:
      @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<GUID>?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
      ) -> HRESULT
    var addRef: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var release: @convention(c) (UnsafeMutableRawPointer?) -> UInt32
    var invoke:
      @convention(c) (
        UnsafeMutableRawPointer?, HRESULT, UnsafeMutableRawPointer?
      ) -> HRESULT
  }

  private func makeCompletionHandlerVTable() -> UnsafeMutablePointer<CompletionHandlerVTable> {
    let table = UnsafeMutablePointer<CompletionHandlerVTable>.allocate(capacity: 1)
    table.initialize(
      to: CompletionHandlerVTable(
        queryInterface: completionHandlerQueryInterface,
        addRef: completionHandlerAddRef,
        release: completionHandlerRelease,
        invoke: completionHandlerInvoke
      )
    )
    return table
  }

  /// Creates a completion handler COM object with one reference owned by the
  /// caller. WebView2 retains its own reference for an accepted asynchronous
  /// operation, so the caller releases this reference after the API returns.
  func webView2CompletionHandler(
    _ onCompleted: @escaping (HRESULT, UnsafeMutableRawPointer?) -> Void
  ) -> UnsafeMutableRawPointer {
    let vtable = makeCompletionHandlerVTable()
    let object = UnsafeMutablePointer<CompletionHandlerObject>.allocate(capacity: 1)
    object.initialize(
      to: CompletionHandlerObject(
        vtable: vtable,
        refCount: 1,
        context: Unmanaged.passRetained(CompletionHandlerContext(onCompleted: onCompleted))
      )
    )
    return UnsafeMutableRawPointer(object)
  }

  private func completionHandlerQueryInterface(
    _ this: UnsafeMutableRawPointer?,
    _ iid: UnsafePointer<GUID>?,
    _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  ) -> HRESULT {
    guard let this, let iid, let output else { return webview2EPointer }
    output.pointee = nil
    let requested = iid.pointee
    if sameGUID(requested, iidIUnknown) || sameGUID(requested, iidEnvironmentHandler)
      || sameGUID(requested, iidControllerHandler)
    {
      output.pointee = this
      _ = completionHandlerAddRef(this)
      return webview2SOK
    }
    return webview2ENoInterface
  }

  private func completionHandlerAddRef(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: CompletionHandlerObject.self)
    object.pointee.refCount += 1
    return object.pointee.refCount
  }

  private func completionHandlerRelease(_ this: UnsafeMutableRawPointer?) -> UInt32 {
    guard let this else { return 0 }
    let object = this.assumingMemoryBound(to: CompletionHandlerObject.self)
    object.pointee.refCount -= 1
    let refCount = object.pointee.refCount
    if refCount == 0 {
      let context = object.pointee.context
      let vtable = object.pointee.vtable
      object.deinitialize(count: 1)
      object.deallocate()
      context.release()
      vtable.deinitialize(count: 1)
      vtable.deallocate()
    }
    return refCount
  }

  private func completionHandlerInvoke(
    _ this: UnsafeMutableRawPointer?,
    _ errorCode: HRESULT,
    _ created: UnsafeMutableRawPointer?
  ) -> HRESULT {
    guard let this else { return webview2EPointer }
    let context = this.assumingMemoryBound(to: CompletionHandlerObject.self).pointee.context
    context.takeUnretainedValue().onCompleted(errorCode, created)
    return webview2SOK
  }
#endif
