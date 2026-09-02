import Foundation

public struct SessionCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let metadata: SessionMetadata
    public let modifiedAt: Date

    public init(url: URL, metadata: SessionMetadata, modifiedAt: Date) {
        self.url = url
        self.metadata = metadata
        self.modifiedAt = modifiedAt
    }
}

public struct SessionDiscovery: Sendable {
    public let codexRoot: URL
    public let claudeRoot: URL

    public init(
        codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    ) {
        self.codexRoot = codexRoot
        self.claudeRoot = claudeRoot
    }

    public func recentDesktopSessions(provider: Provider, limit: Int = 30) -> [SessionCandidate] {
        let root = provider == .codex ? codexRoot : claudeRoot
        let urls = jsonlFiles(under: root)
            .filter { provider == .codex || !$0.path.contains("/subagents/") }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else { return nil }
                return (url, modified)
            }
            .sorted { $0.1 > $1.1 }

        var candidates: [SessionCandidate] = []
        for (url, modifiedAt) in urls {
            do {
                let metadata: SessionMetadata
                switch provider {
                case .codex: metadata = try CodexLogAdapter().metadata(at: url)
                case .claude: metadata = try ClaudeLogAdapter().metadata(at: url)
                }
                guard metadata.isDesktop, metadata.parentSessionID == nil else { continue }
                candidates.append(SessionCandidate(url: url, metadata: metadata, modifiedAt: modifiedAt))
                if candidates.count >= limit { break }
            } catch {
                continue
            }
        }
        return candidates
    }

    public func detectNewDesktopSession(
        provider: Provider,
        after date: Date,
        excluding paths: Set<String>,
        containing runID: String? = nil
    ) -> SessionCandidate? {
        let candidates = recentDesktopSessions(provider: provider, limit: 20)
            .filter { $0.modifiedAt >= date.addingTimeInterval(-2) && !paths.contains($0.url.path) }

        if let runID, let exact = candidates.first(where: { JSONLReader.contains(runID, at: $0.url) }) {
            return exact
        }
        return candidates.first
    }

    public func allVisiblePaths(provider: Provider) -> Set<String> {
        Set(recentDesktopSessions(provider: provider, limit: 100).map { $0.url.path })
    }

    public func codexDescendants(of rootSessionID: String, startedAt: Date?) -> [URL] {
        let threshold = startedAt?.addingTimeInterval(-60)
        var parentIDs: Set<String> = [rootSessionID]
        var found: [URL] = []
        var remaining = jsonlFiles(under: codexRoot).filter { url in
            guard let threshold else { return true }
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (modified ?? .distantPast) >= threshold
        }

        var discoveredInPass = true
        while discoveredInPass {
            discoveredInPass = false
            var nextRemaining: [URL] = []
            for url in remaining {
                guard let metadata = try? CodexLogAdapter().metadata(at: url),
                      let parentID = metadata.parentSessionID,
                      parentIDs.contains(parentID) else {
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
        let subagents = rootURL.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        return jsonlFiles(under: subagents)
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }
}

public struct SessionAnalyzer: Sendable {
    public let discovery: SessionDiscovery

    public init(discovery: SessionDiscovery = SessionDiscovery()) {
        self.discovery = discovery
    }

    public func analyze(rootURL: URL, provider: Provider) throws -> AnalysisResult {
        switch provider {
        case .codex:
            let root = try CodexLogAdapter().parse(at: rootURL)
            guard root.metadata.isDesktop else {
                throw TokenozercaError.unsupportedFormat("Wybrana sesja Codexa nie pochodzi z aplikacji desktopowej.")
            }
            let children = discovery.codexDescendants(
                of: root.metadata.sessionID,
                startedAt: root.metadata.startedAt
            ).compactMap { try? CodexLogAdapter().parse(at: $0) }
            var sessions = [root] + children
            if !children.isEmpty {
                sessions[0] = addingWarning(
                    "Usage subagentów Codexa jest dodawane oddzielnie; polityka wymaga kontrolowanego testu agregacji po aktualizacji aplikacji.",
                    to: sessions[0]
                )
            }
            return AnalysisResult(root: root.metadata, sessions: sessions)

        case .claude:
            let root = try ClaudeLogAdapter().parse(at: rootURL)
            guard root.metadata.isDesktop else {
                throw TokenozercaError.unsupportedFormat("Wybrana sesja Claude nie pochodzi z aplikacji desktopowej.")
            }
            let children = discovery.claudeSubagents(for: rootURL).compactMap {
                try? ClaudeLogAdapter().parse(at: $0, rootSessionID: root.metadata.sessionID)
            }
            var sessions = [root] + children
            if !children.isEmpty {
                sessions[0] = addingWarning(
                    "Usage subagentów Claude jest dodawane oddzielnie; polityka wymaga kontrolowanego testu agregacji po aktualizacji aplikacji.",
                    to: sessions[0]
                )
            }
            return AnalysisResult(root: root.metadata, sessions: sessions)
        }
    }

    private func addingWarning(_ warning: String, to session: ParsedSession) -> ParsedSession {
        ParsedSession(
            metadata: session.metadata,
            records: session.records,
            toolCallCount: session.toolCallCount,
            warnings: session.warnings + [warning],
            parserVersion: session.parserVersion
        )
    }
}
