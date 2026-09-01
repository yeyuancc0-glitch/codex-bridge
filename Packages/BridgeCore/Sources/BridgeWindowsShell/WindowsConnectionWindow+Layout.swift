#if os(Windows)
  import WinSDK

  extension WindowsConnectionWindow {
    static func createControls(parent: HWND, instance: HINSTANCE?) {
      clientList = child(
        "LISTBOX", style: WindowsAuxiliaryControlSupport.listStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: clientListID)
      detail = child(
        "EDIT", style: WindowsAuxiliaryControlSupport.readOnlyTextStyle,
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: detailID)
      endpoint = child(
        "EDIT", style: DWORD(ES_AUTOHSCROLL) | DWORD(ES_READONLY),
        exStyle: WindowsAuxiliaryControlSupport.edgeStyle,
        parent: parent, instance: instance, id: endpointID)
      exposureCombo = child(
        "COMBOBOX", style: WindowsAuxiliaryControlSupport.comboStyle,
        parent: parent, instance: instance, id: exposureID)
      toggleButton = button("启用 Qwen Studio", id: toggleID, parent: parent, instance: instance)
      saveExposureButton = button("保存工具权限", id: saveExposureID, parent: parent, instance: instance)
      copyButton = button("复制 Qwen JSON", id: copyID, parent: parent, instance: instance)
      rotateCredentialButton = button(
        "重新生成 Qwen 凭证", id: rotateCredentialID, parent: parent, instance: instance)
      rotateEndpointButton = button(
        "重新生成 Endpoint", id: rotateEndpointID, parent: parent, instance: instance)
      refreshButton = button("刷新", id: refreshID, parent: parent, instance: instance)
      status = child("STATIC", parent: parent, instance: instance, id: statusID)
      for control in [
        toggleButton, saveExposureButton, copyButton, rotateCredentialButton,
        rotateEndpointButton,
      ] {
        _ = EnableWindow(control, false)
      }
    }

    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      let width = area.right - area.left
      let height = area.bottom - area.top
      let padding = Int32(16)
      let leftWidth = min(Int32(330), max(Int32(240), width / 3))
      let rightX = padding + leftWidth + 14
      let rightWidth = max(Int32(240), width - rightX - padding)
      let endpointTop = Int32(16)
      let detailTop = Int32(52)
      let detailHeight = max(Int32(150), height - 202)
      let actionsTop = detailTop + detailHeight + 12
      _ = MoveWindow(clientList, padding, endpointTop, leftWidth, height - 70, true)
      _ = MoveWindow(endpoint, rightX, endpointTop, rightWidth, 24, true)
      _ = MoveWindow(detail, rightX, detailTop, rightWidth, detailHeight, true)
      _ = MoveWindow(exposureCombo, rightX, actionsTop, 150, 180, true)
      _ = MoveWindow(saveExposureButton, rightX + 160, actionsTop, 118, 24, true)
      _ = MoveWindow(toggleButton, rightX + 288, actionsTop, 142, 24, true)
      _ = MoveWindow(copyButton, rightX, actionsTop + 34, 130, 24, true)
      _ = MoveWindow(rotateCredentialButton, rightX + 140, actionsTop + 34, 166, 24, true)
      _ = MoveWindow(rotateEndpointButton, rightX + 316, actionsTop + 34, 150, 24, true)
      _ = MoveWindow(refreshButton, padding, height - 40, 76, 24, true)
      _ = MoveWindow(status, padding + 88, height - 40, width - padding - 88, 28, true)
    }

    private static func button(
      _ text: String, id: Int, parent: HWND?, instance: HINSTANCE?
    ) -> HWND? {
      child(
        "BUTTON", text: text, style: DWORD(BS_PUSHBUTTON),
        parent: parent, instance: instance, id: id)
    }

    private static func child(
      _ className: String,
      text: String = "",
      style: DWORD = 0,
      exStyle: DWORD = 0,
      parent: HWND?,
      instance: HINSTANCE?,
      id: Int
    ) -> HWND? {
      WindowsUIFoundation.createChild(
        className, text: text, style: style, exStyle: exStyle,
        parent: parent, instance: instance, id: id)
    }
  }
#endif
