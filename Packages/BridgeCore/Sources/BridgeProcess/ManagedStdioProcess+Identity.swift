import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension ManagedStdioProcess {
  public static func identity(of processID: Int32) -> ManagedProcessIdentity? {
    guard processID > 1,
      systemGetPGID(processID) == processID,
      let startTimeMicros = startTimeMicros(processID)
    else { return nil }
    return ManagedProcessIdentity(
      pid: processID,
      startTimeMicros: startTimeMicros,
      processGroupID: processID
    )
  }

  public static func matchesCurrentProcess(_ identity: ManagedProcessIdentity) -> Bool {
    Self.identity(of: identity.pid) == identity
  }

  static func startTimeMicros(_ processID: Int32) -> Int64? {
    #if canImport(Darwin)
      var info = proc_bsdinfo()
      let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
      }
      guard result == expectedSize else { return nil }
      let (base, overflow) = Int64(info.pbi_start_tvsec).multipliedReportingOverflow(by: 1_000_000)
      guard !overflow else { return nil }
      let (total, additionOverflow) = base.addingReportingOverflow(Int64(info.pbi_start_tvusec))
      return additionOverflow ? nil : total
    #else
      guard let data = FileManager.default.contents(atPath: "/proc/\(processID)/stat"),
        let stat = String(data: data, encoding: .utf8),
        let close = stat.lastIndex(of: ")")
      else { return nil }
      let fields = stat[stat.index(after: close)...].split(separator: " ")
      guard fields.count > 19, let ticks = Int64(fields[19]) else { return nil }
      let ticksPerSecond = Int64(sysconf(Int32(_SC_CLK_TCK)))
      guard ticksPerSecond > 0 else { return nil }
      return ticks * 1_000_000 / ticksPerSecond
    #endif
  }
}

#if canImport(Darwin)
  private let systemGetPGID = Darwin.getpgid
#else
  private let systemGetPGID = Glibc.getpgid
#endif
