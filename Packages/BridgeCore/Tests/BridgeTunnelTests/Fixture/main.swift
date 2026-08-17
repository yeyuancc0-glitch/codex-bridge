import Darwin
import Foundation

func readAll(_ descriptor: Int32) -> Data {
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  return handle.readDataToEndOfFile()
}

func argumentValue(_ name: String, in arguments: [String]) -> String? {
  if let index = arguments.firstIndex(of: name), index + 1 < arguments.count {
    return arguments[index + 1]
  }
  let prefix = "\(name)="
  return arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
}

func record(directory: URL, key: String, mcpSecret: String, configuredURL: String) {
  var input = UInt8(0)
  let stdinReachedEOF = read(STDIN_FILENO, &input, 1) == 0
  let payload: [String: Any] = [
    "arguments": CommandLine.arguments,
    "configured_url": configuredURL,
    "environment": ProcessInfo.processInfo.environment,
    "key": key,
    "mcp_secret": mcpSecret,
    "pid": getpid(),
    "stdin_eof": stdinReachedEOF,
  ]
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  try! data.write(to: directory.appendingPathComponent("observed.json"))
}

func serve(healthURLFile: String, tunnelID: String) -> Never {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { exit(11) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let bindStatus = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bindStatus == 0, listen(descriptor, 8) == 0 else { exit(12) }

  var bound = sockaddr_in()
  var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
  let nameStatus = withUnsafeMutablePointer(to: &bound) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(descriptor, $0, &boundLength)
    }
  }
  guard nameStatus == 0 else { exit(13) }
  let port = UInt16(bigEndian: bound.sin_port)
  writePrivateFile(
    path: healthURLFile,
    data: Data("http://127.0.0.1:\(port)".utf8)
  )

  var accepted = 0
  while true {
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { continue }
    let request = String(decoding: readAllRequest(client), as: UTF8.self)
    let now = Date().timeIntervalSince1970
    let body: String
    if request.hasPrefix("GET /readyz ") {
      body = tunnelID.contains("notready") ? "no" : "ready"
    } else if tunnelID.contains("stale") {
      body = "commands_poll_last_successful_timestamp_seconds 0 \(Int(now * 1_000))\n"
    } else {
      body = "commands_poll_last_successful_timestamp_seconds \(now) \(Int(now * 1_000))\n"
    }
    let contentLength = tunnelID.contains("badlength") ? "" : String(body.utf8.count)
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(contentLength)\r\n\r\n\(body)"
    _ = response.withCString { send(client, $0, strlen($0), MSG_NOSIGNAL) }
    close(client)
    accepted += 1
    if tunnelID.contains("laterexit"), accepted >= 2 { exit(7) }
  }
}

func writePrivateFile(path: String, data: Data) {
  let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard descriptor >= 0 else { exit(14) }
  defer { close(descriptor) }
  let succeeded = data.withUnsafeBytes { bytes -> Bool in
    guard let baseAddress = bytes.baseAddress else { return true }
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
      guard count > 0 else { return false }
      offset += count
    }
    return true
  }
  guard succeeded else { exit(15) }
}

func readAllRequest(_ descriptor: Int32) -> Data {
  var data = Data()
  var bytes = [UInt8](repeating: 0, count: 1_024)
  while !data.contains(Data("\r\n\r\n".utf8)) {
    let count = recv(descriptor, &bytes, bytes.count, 0)
    guard count > 0 else { break }
    data.append(bytes, count: count)
  }
  return data
}

func writeNoAuthDoctorFailure(additionalFailure: Bool) {
  var checks: [[String: Any]] = [
    ["id": "tunnel_id", "status": "PASS", "summary": "fixture tunnel"],
    [
      "id": "control_plane_api_key",
      "status": "PASS",
      "summary": "file:/dev/fd/3",
    ],
    [
      "id": "mcp_server_reachable",
      "status": "PASS",
      "summary": "HTTP 404 from fixture",
    ],
    [
      "id": "oauth_metadata",
      "status": "FAIL",
      "summary": "HTTP 404 from http://127.0.0.1/.well-known/oauth-protected-resource/mcp",
      "evidence": ["HTTP 404"],
    ],
    ["id": "health_listener", "status": "PASS", "summary": "loopback ready"],
    ["id": "codex_plugin", "status": "SKIP", "summary": "not installed"],
  ]
  var failedChecks = ["oauth_metadata"]
  if additionalFailure {
    checks[4] = ["id": "health_listener", "status": "FAIL", "summary": "bind failed"]
    failedChecks.append("health_listener")
  }
  let report: [String: Any] = [
    "result": "fail",
    "failed_checks": failedChecks,
    "checks": checks,
  ]
  let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([0x0A]))
}

let arguments = CommandLine.arguments
guard
  let runtimePath = ProcessInfo.processInfo.environment["TMPDIR"],
  let configuredURL = argumentValue("--mcp.server-url", in: arguments),
  let tunnelID = argumentValue("--control-plane.tunnel-id", in: arguments),
  let healthURLFile = argumentValue("--health.url-file", in: arguments),
  argumentValue("--health.listen-addr", in: arguments) == "127.0.0.1:0",
  argumentValue("--control-plane.api-key", in: arguments) == "file:/dev/fd/3",
  argumentValue("--mcp.extra-headers", in: arguments)
    == "X-Codex-Bridge-Token: file:/dev/fd/4"
else {
  exit(10)
}
let key = String(decoding: readAll(3), as: UTF8.self)
let mcpSecret = String(decoding: readAll(4), as: UTF8.self)
record(
  directory: URL(fileURLWithPath: runtimePath, isDirectory: true),
  key: key,
  mcpSecret: mcpSecret,
  configuredURL: configuredURL
)
print("runtime-key=\(key) mcp-secret=\(mcpSecret)")
FileHandle.standardError.write(Data("warn key=\(key) secret=\(mcpSecret)\n".utf8))
if tunnelID.contains("authfail") {
  FileHandle.standardOutput.write(Data("{\"status_code\": 401}\n".utf8))
}
if arguments.contains("doctor") {
  if tunnelID.contains("multifaildoctor") {
    writeNoAuthDoctorFailure(additionalFailure: true)
    exit(2)
  }
  if tunnelID.contains("noauthdoctor") {
    writeNoAuthDoctorFailure(additionalFailure: false)
    exit(2)
  }
  if tunnelID.contains("doctorfail") { exit(2) }
  if tunnelID.contains("slowdoctor") {
    while true { pause() }
  }
  print("{\"ok\":true}")
  exit(0)
}
if tunnelID.contains("ignoreterm") { signal(SIGTERM, SIG_IGN) }
if tunnelID.contains("exit"), !tunnelID.contains("laterexit") { exit(7) }
serve(healthURLFile: healthURLFile, tunnelID: tunnelID)
