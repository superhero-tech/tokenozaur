import Foundation

public struct SessionCandidate: Codable, Equatable, Identifiable, Sendable {
  public var id: String { url.path }
  public let url: URL
  public let metadata: SessionMetadata
  public let modifiedAt: Date
  public let threadName: String?

  public init(url: URL, metadata: SessionMetadata, modifiedAt: Date, threadName: String? = nil) {
    self.url = url
    self.metadata = metadata
    self.modifiedAt = modifiedAt
    self.threadName = threadName
  }

  public var displayName: String {
    if let threadName, !threadName.isEmpty {
      return threadName
    }
    if let workingDirectory = metadata.workingDirectory {
      let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
      if !name.isEmpty { return name }
    }
    return "Rozmowa \(metadata.sessionID.prefix(8))"
  }
}

public struct SessionDiscovery: Sendable {
  public let codexRoot: URL
  public let codexArchiveRoot: URL?
  public let claudeRoot: URL
  public let titleIndex: SessionTitleIndex

  public init(
    codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true),
    codexArchiveRoot: URL? = nil,
    claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/projects", isDirectory: true),
    titleIndex: SessionTitleIndex = SessionTitleIndex()
  ) {
    self.codexRoot = codexRoot
    let defaultActive = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
    if let codexArchiveRoot {
      self.codexArchiveRoot = codexArchiveRoot
    } else if codexRoot.standardizedFileURL == defaultActive.standardizedFileURL {
      self.codexArchiveRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/archived_sessions", isDirectory: true)
    } else {
      self.codexArchiveRoot = nil
    }
    self.claudeRoot = claudeRoot
    self.titleIndex = titleIndex
  }

  public func recentInteractiveSessions(provider: Provider, limit: Int = 30) -> [SessionCandidate] {
    let urls = providerFiles(provider)
      .filter { provider == .codex || !$0.path.contains("/subagents/") }
    let titles = titleIndex.titles(for: provider)

    var candidatesBySessionID: [String: SessionCandidate] = [:]
    for url in urls {
      do {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
          let modifiedAt = values.contentModificationDate
        else { continue }
        let metadata: SessionMetadata
        switch provider {
        case .codex: metadata = try CodexLogAdapter().metadata(at: url)
        case .claude: metadata = try ClaudeLogAdapter().metadata(at: url)
        }
        guard metadata.isInteractive, metadata.parentSessionID == nil else { continue }
        let candidate = SessionCandidate(
          url: url,
          metadata: metadata,
          modifiedAt: modifiedAt,
          threadName: titles[metadata.sessionID]
        )
        if let existing = candidatesBySessionID[metadata.sessionID] {
          if provider == .codex, isActiveCodexURL(url), !isActiveCodexURL(existing.url) {
            candidatesBySessionID[metadata.sessionID] = candidate
          }
        } else {
          candidatesBySessionID[metadata.sessionID] = candidate
        }
      } catch {
        continue
      }
    }
    return Array(candidatesBySessionID.values)
      .sorted { $0.modifiedAt > $1.modifiedAt }
      .prefix(limit)
      .map { $0 }
  }

  public func detectNewInteractiveSession(
    provider: Provider,
    after date: Date,
    excluding paths: Set<String>,
    containing runID: String? = nil
  ) -> SessionCandidate? {
    let candidates = recentInteractiveSessions(provider: provider, limit: 20)
      .filter { $0.modifiedAt >= date.addingTimeInterval(-2) && !paths.contains($0.url.path) }

    if let runID, let exact = candidates.first(where: { JSONLReader.contains(runID, at: $0.url) }) {
      return exact
    }
    return candidates.first
  }

  public func allVisiblePaths(provider: Provider) -> Set<String> {
    Set(recentInteractiveSessions(provider: provider, limit: 100).map { $0.url.path })
  }

  public func allInteractiveSessionFiles(provider: Provider) -> [SessionCandidate] {
    let titles = titleIndex.titles(for: provider)
    let candidates = providerFiles(provider)
      .compactMap { url -> SessionCandidate? in
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
          let modifiedAt = values.contentModificationDate
        else { return nil }
        do {
          let metadata: SessionMetadata
          switch provider {
          case .codex: metadata = try CodexLogAdapter().metadata(at: url)
          case .claude: metadata = try ClaudeLogAdapter().metadata(at: url)
          }
          guard metadata.isInteractive else { return nil }
          return SessionCandidate(
            url: url,
            metadata: metadata,
            modifiedAt: modifiedAt,
            threadName: titles[metadata.sessionID]
          )
        } catch {
          return nil
        }
      }
    guard provider == .codex else {
      return candidates.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    var bySessionID: [String: SessionCandidate] = [:]
    for candidate in candidates {
      if let existing = bySessionID[candidate.metadata.sessionID] {
        if isActiveCodexURL(candidate.url), !isActiveCodexURL(existing.url) {
          bySessionID[candidate.metadata.sessionID] = candidate
        }
      } else {
        bySessionID[candidate.metadata.sessionID] = candidate
      }
    }
    return bySessionID.values.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  public func codexDescendants(of rootSessionID: String, startedAt: Date?) -> [URL] {
    let threshold = startedAt?.addingTimeInterval(-60)
    var parentIDs: Set<String> = [rootSessionID]
    var found: [URL] = []
    var remaining = providerFiles(.codex).filter { url in
      guard let threshold else { return true }
      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      return (modified ?? .distantPast) >= threshold
    }

    var discoveredInPass = true
    while discoveredInPass {
      discoveredInPass = false
      var nextRemaining: [URL] = []
      for url in remaining {
        guard let metadata = try? CodexLogAdapter().metadata(at: url),
          let parentID = metadata.parentSessionID,
          parentIDs.contains(parentID)
        else {
          nextRemaining.append(url)
          continue
        }
        if !parentIDs.contains(metadata.sessionID) {
          parentIDs.insert(metadata.sessionID)
          found.append(url)
          discoveredInPass = true
        }
      }
      remaining = nextRemaining
    }
    return found
  }

  public func claudeSubagents(for rootURL: URL) -> [URL] {
    let subagents = rootURL.deletingPathExtension().appendingPathComponent(
      "subagents", isDirectory: true)
    return jsonlFiles(under: subagents)
  }

  private func providerFiles(_ provider: Provider) -> [URL] {
    switch provider {
    case .claude:
      return jsonlFiles(under: claudeRoot)
    case .codex:
      var seenPaths: Set<String> = []
      let roots = [codexRoot] + (codexArchiveRoot.map { [$0] } ?? [])
      return roots.flatMap { jsonlFiles(under: $0) }.filter { url in
        seenPaths.insert(url.standardizedFileURL.path).inserted
      }
    }
  }

  private func isActiveCodexURL(_ url: URL) -> Bool {
    let activePath = codexRoot.standardizedFileURL.path + "/"
    return url.standardizedFileURL.path.hasPrefix(activePath)
  }

  private func jsonlFiles(under root: URL) -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path),
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      files.append(url)
    }
    return files
  }
}

public struct SessionAnalyzer: Sendable {
  public let discovery: SessionDiscovery
  private let normalizer = UsageNormalizer()

  public init(discovery: SessionDiscovery = SessionDiscovery()) {
    self.discovery = discovery
  }

  public func analyze(rootURL: URL, provider: Provider) throws -> AnalysisResult {
    switch provider {
    case .codex:
      let root = try CodexLogAdapter().parse(at: rootURL)
      guard root.metadata.isInteractive else {
        throw TokenozaurError.unsupportedFormat(
          "Wybrana sesja Codexa nie jest sesją interaktywną Desktop/CLI.")
      }
      let children = discovery.codexDescendants(
        of: root.metadata.sessionID,
        startedAt: root.metadata.startedAt
      ).compactMap { try? CodexLogAdapter().parse(at: $0) }
      let sessions = normalizer.normalize([root] + children)
      return AnalysisResult(root: root.metadata, sessions: sessions)

    case .claude:
      let root = try ClaudeLogAdapter().parse(at: rootURL)
      guard root.metadata.isInteractive else {
        throw TokenozaurError.unsupportedFormat(
          "Wybrana sesja Claude nie jest sesją interaktywną Desktop/CLI.")
      }
      let children = discovery.claudeSubagents(for: rootURL).compactMap {
        try? ClaudeLogAdapter().parse(at: $0, rootSessionID: root.metadata.sessionID)
      }
      let sessions = normalizer.normalize([root] + children)
      return AnalysisResult(root: root.metadata, sessions: sessions)
    }
  }
}
