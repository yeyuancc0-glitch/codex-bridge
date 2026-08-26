import BridgeAgentCore
import Foundation
import GRDB

extension SimpleServiceStore {
  public func insertAgentInstallation(_ installation: ServiceAgentInstallationRecord) throws {
    let capabilities = try Self.encodeCapabilities(installation.capabilities)
    do {
      try database.write { db in
        if try Self.agentInstallationRow(id: installation.id, in: db) != nil {
          throw ServiceStoreError.duplicateAgentInstallation(installation.id)
        }
        if try Self.agentInstallationRow(
          providerID: installation.providerID,
          canonicalPath: installation.executableIdentity.canonicalPath,
          in: db
        ) != nil {
          throw ServiceStoreError.duplicateAgentExecutable(
            providerID: installation.providerID,
            canonicalPath: installation.executableIdentity.canonicalPath
          )
        }
        try Self.insertAgentInstallation(installation, capabilities: capabilities, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      if (try? agentInstallation(id: installation.id)) != nil {
        throw ServiceStoreError.duplicateAgentInstallation(installation.id)
      }
      if (try? agentInstallation(
        providerID: installation.providerID,
        canonicalPath: installation.executableIdentity.canonicalPath
      )) != nil {
        throw ServiceStoreError.duplicateAgentExecutable(
          providerID: installation.providerID,
          canonicalPath: installation.executableIdentity.canonicalPath
        )
      }
      throw ServiceStoreError.storageFailure
    }
  }

  public func updateAgentInstallation(_ installation: ServiceAgentInstallationRecord) throws {
    let capabilities = try Self.encodeCapabilities(installation.capabilities)
    do {
      try database.write { db in
        guard let row = try Self.agentInstallationRow(id: installation.id, in: db) else {
          throw ServiceStoreError.unknownAgentInstallation(installation.id)
        }
        let existing = try Self.decodeAgentInstallation(row)
        guard existing.providerID == installation.providerID,
          existing.executablePath == installation.executablePath,
          existing.createdAt == installation.createdAt,
          installation.updatedAt >= existing.updatedAt
        else {
          throw ServiceStoreError.invalidArgument("agentInstallation.update")
        }
        if let conflicting = try Self.agentInstallationRow(
          providerID: installation.providerID,
          canonicalPath: installation.executableIdentity.canonicalPath,
          in: db
        ) {
          let conflictingID: String = conflicting["installation_id"]
          guard conflictingID == installation.id.rawValue else {
            throw ServiceStoreError.duplicateAgentExecutable(
              providerID: installation.providerID,
              canonicalPath: installation.executableIdentity.canonicalPath
            )
          }
        }
        try db.execute(
          sql: """
            UPDATE bridge_service_agent_installations
            SET display_name = ?, canonical_executable_path = ?, executable_device = ?,
                executable_inode = ?, executable_size = ?, executable_mtime_ns = ?,
                executable_sha256 = ?, version = ?, protocol_revision = ?,
                adapter_revision = ?, trust_profile = ?, security_profile_id = ?,
                is_enabled = ?, availability = ?, capabilities_json = ?,
                last_probe_error = ?, last_probed_at = ?, updated_at = ?
            WHERE installation_id = ?
            """,
          arguments: Self.agentInstallationArguments(
            installation,
            capabilities: capabilities,
            includeImmutableFields: false
          )
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func agentInstallation(id: AgentInstallationID) throws
    -> ServiceAgentInstallationRecord?
  {
    do {
      return try database.read { db in
        try Self.agentInstallationRow(id: id, in: db).map(Self.decodeAgentInstallation)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func agentInstallations(providerID: AgentProviderID? = nil) throws
    -> [ServiceAgentInstallationRecord]
  {
    do {
      return try database.read { db in
        let rows: [Row]
        if let providerID {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_agent_installations
              WHERE provider_id = ?
              ORDER BY display_name COLLATE NOCASE, installation_id
              """,
            arguments: [providerID.rawValue]
          )
        } else {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_agent_installations
              ORDER BY provider_id, display_name COLLATE NOCASE, installation_id
              """
          )
        }
        return try rows.map(Self.decodeAgentInstallation)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func removeAgentInstallation(id: AgentInstallationID) throws {
    do {
      try database.write { db in
        guard try Self.agentInstallationRow(id: id, in: db) != nil else {
          throw ServiceStoreError.unknownAgentInstallation(id)
        }
        try db.execute(
          sql: "DELETE FROM bridge_service_agent_installations WHERE installation_id = ?",
          arguments: [id.rawValue]
        )
        guard db.changesCount == 1 else { throw ServiceStoreError.storageFailure }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private func agentInstallation(
    providerID: AgentProviderID,
    canonicalPath: String
  ) throws -> ServiceAgentInstallationRecord? {
    try database.read { db in
      try Self.agentInstallationRow(
        providerID: providerID,
        canonicalPath: canonicalPath,
        in: db
      ).map(Self.decodeAgentInstallation)
    }
  }

  private static func insertAgentInstallation(
    _ installation: ServiceAgentInstallationRecord,
    capabilities: Data,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_installations (
          installation_id, provider_id, display_name, executable_path,
          canonical_executable_path, executable_device, executable_inode,
          executable_size, executable_mtime_ns, executable_sha256, version,
          protocol_revision, adapter_revision, trust_profile, security_profile_id,
          is_enabled, availability, capabilities_json, last_probe_error,
          last_probed_at, created_at, updated_at
        ) VALUES (
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        """,
      arguments: agentInstallationArguments(
        installation,
        capabilities: capabilities,
        includeImmutableFields: true
      )
    )
  }

  private static func agentInstallationArguments(
    _ installation: ServiceAgentInstallationRecord,
    capabilities: Data,
    includeImmutableFields: Bool
  ) -> StatementArguments {
    let mutable: [DatabaseValueConvertible?] = [
      installation.displayName,
      installation.executableIdentity.canonicalPath,
      String(installation.executableIdentity.device),
      String(installation.executableIdentity.inode),
      String(installation.executableIdentity.fileSize),
      installation.executableIdentity.modificationTimeNanoseconds,
      installation.executableIdentity.sha256,
      installation.version,
      installation.protocolRevision,
      installation.adapterRevision,
      installation.trustProfile.rawValue,
      installation.securityProfileID?.rawValue,
      installation.isEnabled ? 1 : 0,
      installation.availability.rawValue,
      capabilities,
      installation.lastProbeError,
      installation.lastProbedAt?.timeIntervalSince1970,
      installation.updatedAt.timeIntervalSince1970,
      installation.id.rawValue,
    ]
    guard includeImmutableFields else { return StatementArguments(mutable) }
    return StatementArguments(
      [
        installation.id.rawValue,
        installation.providerID.rawValue,
        installation.displayName,
        installation.executablePath,
        installation.executableIdentity.canonicalPath,
        String(installation.executableIdentity.device),
        String(installation.executableIdentity.inode),
        String(installation.executableIdentity.fileSize),
        installation.executableIdentity.modificationTimeNanoseconds,
        installation.executableIdentity.sha256,
        installation.version,
        installation.protocolRevision,
        installation.adapterRevision,
        installation.trustProfile.rawValue,
        installation.securityProfileID?.rawValue,
        installation.isEnabled ? 1 : 0,
        installation.availability.rawValue,
        capabilities,
        installation.lastProbeError,
        installation.lastProbedAt?.timeIntervalSince1970,
        installation.createdAt.timeIntervalSince1970,
        installation.updatedAt.timeIntervalSince1970,
      ] as [DatabaseValueConvertible?])
  }

  private static func agentInstallationRow(
    id: AgentInstallationID,
    in db: Database
  ) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM bridge_service_agent_installations WHERE installation_id = ?",
      arguments: [id.rawValue]
    )
  }

  private static func agentInstallationRow(
    providerID: AgentProviderID,
    canonicalPath: String,
    in db: Database
  ) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM bridge_service_agent_installations
        WHERE provider_id = ? AND canonical_executable_path = ?
        """,
      arguments: [providerID.rawValue, canonicalPath]
    )
  }

  private static func decodeAgentInstallation(_ row: Row) throws
    -> ServiceAgentInstallationRecord
  {
    guard let device = UInt64(row["executable_device"] as String),
      let inode = UInt64(row["executable_inode"] as String),
      let fileSize = UInt64(row["executable_size"] as String),
      let trustProfile = AgentTrustProfile(rawValue: row["trust_profile"]),
      let availability = ServiceAgentInstallationAvailability(rawValue: row["availability"])
    else {
      throw ServiceStoreError.corruptRecord
    }
    let enabled: Int = row["is_enabled"]
    guard enabled == 0 || enabled == 1 else { throw ServiceStoreError.corruptRecord }
    let capabilitiesData: Data = row["capabilities_json"]
    let capabilities: AgentCapabilitySnapshot
    do {
      capabilities = try JSONDecoder().decode(AgentCapabilitySnapshot.self, from: capabilitiesData)
    } catch {
      throw ServiceStoreError.corruptRecord
    }
    let identity = try ServiceAgentExecutableIdentity(
      canonicalPath: row["canonical_executable_path"],
      device: device,
      inode: inode,
      fileSize: fileSize,
      modificationTimeNanoseconds: row["executable_mtime_ns"],
      sha256: row["executable_sha256"]
    )
    let securityProfile: String? = row["security_profile_id"]
    let lastProbedAt: Double? = row["last_probed_at"]
    return try ServiceAgentInstallationRecord(
      id: AgentInstallationID(rawValue: row["installation_id"]),
      providerID: AgentProviderID(rawValue: row["provider_id"]),
      displayName: row["display_name"],
      executablePath: row["executable_path"],
      executableIdentity: identity,
      version: row["version"],
      protocolRevision: row["protocol_revision"],
      adapterRevision: row["adapter_revision"],
      trustProfile: trustProfile,
      securityProfileID: securityProfile.map(AgentProfileID.init(rawValue:)),
      isEnabled: enabled == 1,
      availability: availability,
      capabilities: capabilities,
      lastProbeError: row["last_probe_error"],
      lastProbedAt: lastProbedAt.map(Date.init(timeIntervalSince1970:)),
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }

  private static func encodeCapabilities(_ capabilities: AgentCapabilitySnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(capabilities)
    guard data.count <= 65_536 else {
      throw ServiceStoreError.invalidArgument("agentInstallation.capabilities")
    }
    return data
  }
}
