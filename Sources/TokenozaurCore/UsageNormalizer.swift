import Foundation

public struct UsageNormalizer: Sendable {
  public static let version = "usage-normalizer-v1"
  private static let replayBurstPause: TimeInterval = 1

  private struct ClaudeCandidate {
    let sessionIndex: Int
    let record: UsageRecord
  }

  public init() {}

  public func normalize(_ sessions: [ParsedSession]) -> [ParsedSession] {
    let claudeNormalized = normalizeClaudeSidechains(sessions)
    return normalizeCodexReplay(claudeNormalized, rawSessions: sessions)
  }

  private func normalizeClaudeSidechains(_ sessions: [ParsedSession]) -> [ParsedSession] {
    var winnerByKey: [String: ClaudeCandidate] = [:]
    for (sessionIndex, session) in sessions.enumerated() where session.metadata.provider == .claude
    {
      for record in session.records {
        guard let messageID = record.messageID, !messageID.isEmpty else { continue }
        let key = "\(record.sessionID)\u{1F}\(messageID)"
        let candidate = ClaudeCandidate(sessionIndex: sessionIndex, record: record)
        if let existing = winnerByKey[key] {
          if prefers(candidate, over: existing) {
            winnerByKey[key] = candidate
          }
        } else {
          winnerByKey[key] = candidate
        }
      }
    }

    let winningIDs = Set(winnerByKey.values.map(\.record.id))
    return sessions.map { session in
      guard session.metadata.provider == .claude else {
        return carryingNormalizerMetadata(session)
      }
      let filtered = session.records.filter { record in
        guard record.messageID != nil else { return true }
        return winningIDs.contains(record.id)
      }
      let dropped = session.records.count - filtered.count
      let warnings =
        dropped > 0
        ? session.warnings + ["Usunięto \(dropped) powtórzonych rekordów parent/sidechain Claude."]
        : session.warnings
      return rebuilding(
        session,
        records: filtered,
        warnings: warnings,
        accuracy: session.measurementAccuracy ?? .exact,
        dropped: (session.droppedReplayRecordCount ?? 0) + dropped
      )
    }
  }

  private func normalizeCodexReplay(
    _ sessions: [ParsedSession],
    rawSessions: [ParsedSession]
  ) -> [ParsedSession] {
    let rawBySessionID = Dictionary(
      rawSessions.map { ($0.metadata.sessionID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let rawBySourceFile = Dictionary(
      rawSessions.map { ($0.metadata.sourceFile, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    return sessions.map { session in
      guard session.metadata.provider == .codex,
        let parentID = session.metadata.replayParentSessionID,
        parentID != session.metadata.sessionID
      else {
        return carryingNormalizerMetadata(session)
      }

      let rawChild = rawBySourceFile[session.metadata.sourceFile] ?? session
      let parent = rawBySessionID[parentID]
      let parentPrefix = parent.map { parentUsagePrefix($0, forkedAt: rawChild.metadata.startedAt) }
      let decision = replayDecision(child: rawChild.records, parentPrefix: parentPrefix)
      let droppedIDs = Set(decision.droppedRecordIDs)
      let filtered = session.records.filter { !droppedIDs.contains($0.id) }
      var warnings = session.warnings
      if !droppedIDs.isEmpty {
        warnings.append(
          "Usunięto \(droppedIDs.count) rekordów replay odziedziczonych z sesji nadrzędnej Codexa.")
      }

      var accuracy = session.measurementAccuracy ?? .exact
      if decision.usedHeuristic {
        accuracy = .partial
        warnings.append(
          "Replay Codexa rozpoznano heurystycznie po gęstym prefiksie; wynik oznaczono jako częściowy."
        )
      } else if decision.couldNotVerify,
        session.metadata.replayKind != .multiAgentV2
      {
        accuracy = .partial
        warnings.append(
          "Brak logu rodzica lub bezpiecznej granicy replay Codexa; wynik może zawierać odziedziczony prefiks."
        )
      }

      return rebuilding(
        session,
        records: filtered,
        warnings: warnings,
        accuracy: accuracy,
        dropped: (session.droppedReplayRecordCount ?? 0) + droppedIDs.count
      )
    }
  }

  private func parentUsagePrefix(_ parent: ParsedSession, forkedAt: Date?) -> [UsageBreakdown] {
    parent.records
      .filter { record in
        guard let forkedAt else { return true }
        return record.timestamp <= forkedAt
      }
      .map(\.usage)
  }

  private struct ReplayDecision {
    let droppedRecordIDs: [String]
    let usedHeuristic: Bool
    let couldNotVerify: Bool
  }

  private func replayDecision(
    child: [UsageRecord],
    parentPrefix: [UsageBreakdown]?
  ) -> ReplayDecision {
    guard !child.isEmpty else {
      return ReplayDecision(droppedRecordIDs: [], usedHeuristic: false, couldNotVerify: false)
    }

    if let parentPrefix, !parentPrefix.isEmpty {
      var matched: [String] = []
      for (index, record) in child.enumerated() {
        guard index < parentPrefix.count, record.usage == parentPrefix[index] else { break }
        matched.append(record.id)
      }
      if !matched.isEmpty {
        return ReplayDecision(
          droppedRecordIDs: matched, usedHeuristic: false, couldNotVerify: false)
      }
    }

    let densePrefix = denseReplayPrefix(child)
    if !densePrefix.isEmpty {
      return ReplayDecision(
        droppedRecordIDs: densePrefix, usedHeuristic: true, couldNotVerify: false)
    }
    return ReplayDecision(
      droppedRecordIDs: [],
      usedHeuristic: false,
      couldNotVerify: parentPrefix == nil
    )
  }

  private func denseReplayPrefix(_ records: [UsageRecord]) -> [String] {
    guard records.count >= 2 else { return [] }
    let firstGap = records[1].timestamp.timeIntervalSince(records[0].timestamp)
    guard firstGap >= 0, firstGap <= Self.replayBurstPause else { return [] }

    var ids = [records[0].id, records[1].id]
    var previous = records[1].timestamp
    for record in records.dropFirst(2) {
      let gap = record.timestamp.timeIntervalSince(previous)
      guard gap >= 0, gap <= Self.replayBurstPause else { break }
      ids.append(record.id)
      previous = record.timestamp
    }
    return ids
  }

  private func prefers(_ lhs: ClaudeCandidate, over rhs: ClaudeCandidate) -> Bool {
    if lhs.record.isSidechain != rhs.record.isSidechain {
      return lhs.record.isSidechain != true
    }
    if lhs.record.usage.total != rhs.record.usage.total {
      return lhs.record.usage.total > rhs.record.usage.total
    }
    if lhs.record.timestamp != rhs.record.timestamp {
      return lhs.record.timestamp > rhs.record.timestamp
    }
    return lhs.sessionIndex < rhs.sessionIndex
  }

  private func carryingNormalizerMetadata(_ session: ParsedSession) -> ParsedSession {
    rebuilding(
      session,
      records: session.records,
      warnings: session.warnings,
      accuracy: session.measurementAccuracy ?? .exact,
      dropped: session.droppedReplayRecordCount ?? 0
    )
  }

  private func rebuilding(
    _ session: ParsedSession,
    records: [UsageRecord],
    warnings: [String],
    accuracy: MeasurementAccuracy,
    dropped: Int
  ) -> ParsedSession {
    ParsedSession(
      metadata: session.metadata,
      records: records,
      toolCallCount: session.toolCallCount,
      warnings: warnings,
      parserVersion: session.parserVersion,
      normalizerVersion: Self.version,
      measurementAccuracy: accuracy,
      droppedReplayRecordCount: dropped
    )
  }
}
