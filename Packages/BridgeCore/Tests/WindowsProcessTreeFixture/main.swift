import BridgeProcessRuntime
import BridgeWindowsSandboxSupport
import Foundation
import WinSDK

private enum FixtureError: Error {
  case invalidArguments
  case invalidRequest
  case launchFailed(Int32)
}

private func write(_ value: String, to path: String) throws {
  try Data(value.utf8).write(
    to: URL(fileURLWithPath: path),
    options: [.atomic]
  )
}

private func launchChild(executablePath: String, heartbeatPath: String) throws -> UInt32 {
  let commandLine = try WindowsCommandLine.encode([
    executablePath,
    "--child",
    heartbeatPath,
  ])
  var application = Array(executablePath.utf16)
  application.append(0)
  var command = Array(commandLine.utf16)
  command.append(0)
  var startup = STARTUPINFOW()
  startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
  var process = PROCESS_INFORMATION()

  let created = application.withUnsafeBufferPointer { applicationBuffer in
    command.withUnsafeMutableBufferPointer { commandBuffer in
      CreateProcessW(
        applicationBuffer.baseAddress,
        commandBuffer.baseAddress,
        nil,
        nil,
        false,
        DWORD(CREATE_NO_WINDOW),
        nil,
        nil,
        &startup,
        &process
      )
    }
  }
  guard created else { throw FixtureError.launchFailed(Int32(GetLastError())) }
  CloseHandle(process.hThread)
  CloseHandle(process.hProcess)
  return process.dwProcessId
}

private func runChild(heartbeatPath: String) -> Never {
  while true {
    try? write(String(GetTickCount64()), to: heartbeatPath)
    Sleep(50)
  }
}

private func runParent(pidPath: String, heartbeatPath: String) throws -> Never {
  let executablePath = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL.path
  let childPID = try launchChild(
    executablePath: executablePath,
    heartbeatPath: heartbeatPath
  )
  try write(String(childPID), to: pidPath)
  while true {
    Sleep(1_000)
  }
}

private func runAppServer() throws -> Never {
  while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
      let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let method = request["method"] as? String
    else {
      throw FixtureError.invalidRequest
    }
    guard let id = request["id"] else { continue }

    do {
      try sendResponse(id: id, result: responseResult(for: method, request: request))
    } catch FixtureError.invalidRequest {
      try sendError(id: id, message: "unsupported fixture method: \(method)")
    }
  }
  ExitProcess(0)
}

private func responseResult(
  for method: String,
  request: [String: Any]
) throws -> Any {
  switch method {
  case "initialize":
    return [
      "userAgent": "codex-bridge-windows-fixture",
      "codexHome": #"C:\fixture\.codex"#,
      "platformFamily": "windows",
      "platformOs": "windows",
    ]
  case "thread/start":
    let params = request["params"] as? [String: Any]
    return threadStartResult(cwd: params?["cwd"] as? String ?? #"C:\fixture"#)
  case "turn/start":
    return ["turn": turn(status: "inProgress")]
  case "turn/steer":
    return ["turnId": "turn-1"]
  case "turn/interrupt":
    return [String: Any]()
  default:
    throw FixtureError.invalidRequest
  }
}

private func threadStartResult(cwd: String) -> [String: Any] {
  let thread: [String: Any] = [
    "id": "thread-1",
    "cwd": cwd,
    "ephemeral": true,
    "modelProvider": "fixture",
    "preview": "",
    "turns": [],
    "cliVersion": "fixture-1",
    "createdAt": 1,
    "updatedAt": 1,
    "sessionId": "session-1",
    "status": ["type": "idle"],
    "source": ["type": "fixture"],
  ]
  return [
    "thread": thread,
    "model": "fixture-model",
    "modelProvider": "fixture",
    "reasoningEffort": "high",
    "cwd": cwd,
    "sandbox": [
      "type": "workspaceWrite",
      "networkAccess": false,
      "writableRoots": [cwd],
    ],
    "approvalPolicy": "never",
    "approvalsReviewer": "user",
  ]
}

private func turn(status: String) -> [String: Any] {
  [
    "id": "turn-1",
    "status": status,
    "items": [],
    "startedAt": 1,
  ]
}

private func sendResponse(id: Any, result: Any) throws {
  try sendJSON(["id": id, "result": result])
}

private func sendError(id: Any, message: String) throws {
  try sendJSON([
    "id": id,
    "error": [
      "code": -32_601,
      "message": message,
    ],
  ])
}

private func sendJSON(_ object: Any) throws {
  var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  data.append(0x0A)
  try FileHandle.standardOutput.write(contentsOf: data)
}

private func fail(_ error: Error) -> Never {
  let message = "windows-process-tree-fixture: \(error)\n"
  try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  ExitProcess(2)
}

do {
  let arguments = CommandLine.arguments
  guard arguments.count >= 2 else { throw FixtureError.invalidArguments }
  switch arguments[1] {
  case "--sandbox-files" where arguments.count == 4:
    let inside = (try? write("inside", to: arguments[2])) != nil ? "1" : "0"
    let outside = (try? write("outside", to: arguments[3])) != nil ? "1" : "0"
    print("inside=\(inside);outside=\(outside)")
    ExitProcess(0)
  case "--sandbox-network" where arguments.count == 3:
    guard let port = UInt16(arguments[2]) else { throw FixtureError.invalidArguments }
    let appContainer = bridge_current_process_is_app_container() ? "1" : "0"
    let internet = bridge_current_process_has_internet_client_capability() ? "1" : "0"
    let connected = bridge_loopback_connect(port) ? "1" : "0"
    print("appcontainer=\(appContainer);internet=\(internet);connect=\(connected)")
    ExitProcess(0)
  case "--sandbox-token" where arguments.count == 2:
    let appContainer = bridge_current_process_is_app_container() ? "1" : "0"
    let internet = bridge_current_process_has_internet_client_capability() ? "1" : "0"
    print("appcontainer=\(appContainer);internet=\(internet)")
    ExitProcess(0)
  case "--app-server" where arguments.count == 2:
    try runAppServer()
  case "--child" where arguments.count == 3:
    runChild(heartbeatPath: arguments[2])
  case "--parent" where arguments.count == 4:
    try runParent(pidPath: arguments[2], heartbeatPath: arguments[3])
  default:
    throw FixtureError.invalidArguments
  }
} catch {
  fail(error)
}
