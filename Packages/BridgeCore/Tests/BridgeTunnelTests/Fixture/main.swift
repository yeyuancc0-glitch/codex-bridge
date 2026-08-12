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

func serve(socketPath: String, tunnelID: String) -> Never {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(socketPath.utf8CString)
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(13) }
  _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
      bytes.withUnsafeBytes { memcpy(destination, $0.baseAddress!, bytes.count) }
    }
  }
  let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path)!
  let length = socklen_t(pathOffset + bytes.count)
  address.sun_len = UInt8(length)
  unlink(socketPath)
  let bindStatus = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, length)
    }
  }
  guard bindStatus == 0, listen(descriptor, 8) == 0 else { exit(12) }
  var accepted = 0
  while true {
    let client = accept(descriptor, nil, nil)
    guard client >= 0 else { continue }
    let request = String(decoding: readAllRequest(client), as: UTF8.self)
    let now = Date().timeIntervalSince1970
    let body: String
    if request.hasPrefix("GET /readyz ") {
      body = tunnelID.contains("notready") ? "no" : "ready"
    } else {
      body = "commands_poll_last_successful_timestamp_seconds \(now)\n"
    }
    let contentLength = tunnelID.contains("badlength") ? "" : String(body.utf8.count)
    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(contentLength)\r\n\r\n\(body)"
    _ = response.withCString { send(client, $0, strlen($0), MSG_NOSIGNAL) }
    close(client)
    accepted += 1
    if tunnelID.contains("laterexit"), accepted >= 2 { exit(7) }
  }
}

func readAllRequest(_ descriptor: Int32) -> Data {
  var data = Data()
  var bytes = [UInt8](repeating: 0, count: 1024)
  while !data.contains(Data("\r\n\r\n".utf8)) {
    let count = recv(descriptor, &bytes, bytes.count, 0)
    guard count > 0 else { break }
    data.append(bytes, count: count)
  }
  return data
}

let arguments = CommandLine.arguments
guard
  let runtimePath = ProcessInfo.processInfo.environment["TMPDIR"],
  let configuredURL = argumentValue("--mcp.server-url", in: arguments),
  let tunnelID = argumentValue("--control-plane.tunnel-id", in: arguments),
  let socketPath = argumentValue("--health.unix-socket", in: arguments),
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
  if tunnelID.contains("doctorfail") { exit(2) }
  if tunnelID.contains("slowdoctor") {
    while true { pause() }
  }
  print("{\"ok\":true}")
  exit(0)
}
if tunnelID.contains("ignoreterm") { signal(SIGTERM, SIG_IGN) }
if tunnelID.contains("exit"), !tunnelID.contains("laterexit") { exit(7) }
serve(socketPath: socketPath, tunnelID: tunnelID)
