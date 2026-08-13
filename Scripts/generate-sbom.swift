#!/usr/bin/env swift
import Foundation

struct ResolvedPackages: Decodable {
  let originHash: String
  let pins: [Pin]
}

struct Pin: Decodable {
  let identity: String
  let location: String
  let state: State
}

struct State: Decodable {
  let revision: String
  let version: String?
}

enum SBOMError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidResolvedPackage(String)
  case outputExists

  var description: String {
    switch self {
    case .invalidArguments:
      "Usage: generate-sbom.swift PACKAGE_RESOLVED PRODUCT_VERSION CREATED_AT OUTPUT"
    case .invalidResolvedPackage(let identity):
      "Invalid resolved package entry: \(identity)"
    case .outputExists:
      "Refusing to overwrite an existing SBOM output."
    }
  }
}

func requireASCIIIdentifier(_ value: String, maximum: Int) throws {
  guard !value.isEmpty, value.utf8.count <= maximum,
    value.utf8.allSatisfy({ byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || byte == 45 || byte == 46 || byte == 95
    })
  else { throw SBOMError.invalidResolvedPackage(value) }
}

func packageIdentifier(_ identity: String) -> String {
  "SPDXRef-Package-"
    + identity.map { character in
      character.isLetter || character.isNumber || character == "." || character == "-"
        ? character : "-"
    }
}

func percentEncoded(_ value: String) -> String {
  value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
}

func makePackage(_ pin: Pin) throws -> [String: Any] {
  try requireASCIIIdentifier(pin.identity, maximum: 128)
  guard pin.location.hasPrefix("https://"), pin.location.utf8.count <= 2_048,
    pin.state.revision.utf8.count == 40,
    pin.state.revision.utf8.allSatisfy({ byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    })
  else { throw SBOMError.invalidResolvedPackage(pin.identity) }
  let version = pin.state.version ?? pin.state.revision
  let purl = "pkg:swift/\(percentEncoded(pin.identity))@\(percentEncoded(version))"
  return [
    "SPDXID": packageIdentifier(pin.identity),
    "name": pin.identity,
    "versionInfo": version,
    "downloadLocation": pin.location,
    "filesAnalyzed": false,
    "licenseConcluded": "NOASSERTION",
    "licenseDeclared": "NOASSERTION",
    "copyrightText": "NOASSERTION",
    "checksums": [["algorithm": "SHA1", "checksumValue": pin.state.revision]],
    "externalRefs": [
      [
        "referenceCategory": "PACKAGE-MANAGER",
        "referenceType": "purl",
        "referenceLocator": purl,
      ]
    ],
  ]
}

func run() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 5 else { throw SBOMError.invalidArguments }
  let resolvedURL = URL(fileURLWithPath: arguments[1])
  let productVersion = arguments[2]
  let createdAt = arguments[3]
  let outputURL = URL(fileURLWithPath: arguments[4])
  guard !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw SBOMError.outputExists
  }
  try requireASCIIIdentifier(productVersion, maximum: 64)
  let resolved = try JSONDecoder().decode(
    ResolvedPackages.self,
    from: Data(contentsOf: resolvedURL, options: .mappedIfSafe)
  )
  guard resolved.originHash.utf8.count == 64,
    resolved.originHash.utf8.allSatisfy({ byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }),
    resolved.pins.count <= 128
  else { throw SBOMError.invalidResolvedPackage("originHash") }

  let sortedPins = resolved.pins.sorted { $0.identity < $1.identity }
  var packages: [[String: Any]] = [
    [
      "SPDXID": "SPDXRef-Package-CodexBridge",
      "name": "CodexBridge",
      "versionInfo": productVersion,
      "downloadLocation": "NOASSERTION",
      "filesAnalyzed": false,
      "licenseConcluded": "Apache-2.0",
      "licenseDeclared": "Apache-2.0",
      "copyrightText": "Copyright 2026 Codex Bridge contributors",
    ]
  ]
  packages.append(contentsOf: try sortedPins.map(makePackage))
  var relationships: [[String: String]] = [
    [
      "spdxElementId": "SPDXRef-DOCUMENT",
      "relationshipType": "DESCRIBES",
      "relatedSpdxElement": "SPDXRef-Package-CodexBridge",
    ]
  ]
  relationships.append(
    contentsOf: sortedPins.map { pin in
      [
        "spdxElementId": "SPDXRef-Package-CodexBridge",
        "relationshipType": "DEPENDS_ON",
        "relatedSpdxElement": packageIdentifier(pin.identity),
      ]
    })
  let document: [String: Any] = [
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "CodexBridge-\(productVersion)",
    "documentNamespace":
      "https://spdx.org/spdxdocs/codex-bridge-\(productVersion)-\(resolved.originHash)",
    "creationInfo": [
      "created": createdAt,
      "creators": ["Tool: CodexBridge-generate-sbom"],
    ],
    "packages": packages,
    "relationships": relationships,
  ]
  let data = try JSONSerialization.data(
    withJSONObject: document,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  )
  try data.write(to: outputURL, options: .withoutOverwriting)
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
