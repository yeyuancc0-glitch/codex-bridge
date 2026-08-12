import Foundation

public actor GitPatchStore {
  private struct Document: Sendable {
    let bytes: Data
    let isTruncated: Bool
  }

  private let maximumDocumentCount: Int
  private let maximumStoredBytes: Int
  private let maximumPageBytes: Int
  private var documents: [String: Document] = [:]
  private var storedBytes = 0

  public init(
    maximumDocumentCount: Int = 64,
    maximumStoredBytes: Int = 64 * 1_024 * 1_024,
    maximumPageBytes: Int = 200 * 1_024
  ) {
    self.maximumDocumentCount = max(1, maximumDocumentCount)
    self.maximumStoredBytes = max(1, maximumStoredBytes)
    self.maximumPageBytes = max(1, maximumPageBytes)
  }

  func store(_ bytes: Data, isTruncated: Bool) throws -> GitPatchHandle {
    guard documents.count < maximumDocumentCount,
      storedBytes <= maximumStoredBytes - bytes.count
    else {
      throw GitEvidenceError.patchStoreCapacityExceeded
    }
    let random = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let identifier = "patch_\(random)"
    documents[identifier] = Document(bytes: bytes, isTruncated: isTruncated)
    storedBytes += bytes.count
    return GitPatchHandle(
      rawValue: identifier,
      totalBytes: bytes.count,
      isTruncated: isTruncated
    )
  }

  public func page(
    for handle: GitPatchHandle,
    offset: Int = 0,
    maximumBytes requestedMaximumBytes: Int? = nil
  ) throws -> GitPatchPage {
    guard let document = documents[handle.rawValue] else {
      throw GitEvidenceError.patchNotFound
    }
    guard offset >= 0, offset <= document.bytes.count else {
      throw GitEvidenceError.invalidPatchCursor
    }
    let requested = requestedMaximumBytes.map { max(1, $0) } ?? maximumPageBytes
    let pageBytes = min(requested, maximumPageBytes)
    let end = min(document.bytes.count, offset + pageBytes)
    let nextOffset = end < document.bytes.count ? end : nil
    return GitPatchPage(
      bytes: Data(document.bytes[offset..<end]),
      nextOffset: nextOffset,
      totalBytes: document.bytes.count,
      isTruncated: document.isTruncated
    )
  }

  public func discard(_ handle: GitPatchHandle) {
    guard let removed = documents.removeValue(forKey: handle.rawValue) else { return }
    storedBytes -= removed.bytes.count
  }

  public func discardAll() {
    documents.removeAll(keepingCapacity: false)
    storedBytes = 0
  }
}
