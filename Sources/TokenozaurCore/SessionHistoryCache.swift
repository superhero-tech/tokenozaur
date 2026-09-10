import Foundation

public struct CachedSessionSnapshot: Codable, Equatable, Sendable {
  public let candidate: SessionCandidate
  public let session: ParsedSession

  public init(candidate: SessionCandidate, session: ParsedSession) {
    self.candidate = candidate
    self.session = session
  }
}

public struct SessionHistoryCacheStore: Sendable {
  public let storageURL: URL

  public init(storageURL: URL? = nil) {
    self.storageURL =
      storageURL
      ?? TokenozaurStorageLocation.directoryURL
      .appendingPathComponent("session-history-cache.json")
  }

  public func load() -> [String: CachedSessionSnapshot] {
    guard let data = try? Data(contentsOf: storageURL),
      let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
      envelope.version == CacheEnvelope.currentVersion
    else { return [:] }

    return envelope.snapshots.filter { _, snapshot in
      switch snapshot.candidate.metadata.provider {
      case .codex:
        return snapshot.session.parserVersion == CodexLogAdapter.parserVersion
      case .claude:
        return snapshot.session.parserVersion == ClaudeLogAdapter.parserVersion
      }
    }
  }

  public func save(_ snapshots: [String: CachedSessionSnapshot]) throws {
    let directory = storageURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(
      CacheEnvelope(version: CacheEnvelope.currentVersion, snapshots: snapshots)
    )
    try data.write(to: storageURL, options: .atomic)
  }
}

private struct CacheEnvelope: Codable {
  static let currentVersion = 1
  let version: Int
  let snapshots: [String: CachedSessionSnapshot]
}
