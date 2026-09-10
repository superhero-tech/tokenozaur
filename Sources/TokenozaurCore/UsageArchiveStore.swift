import CSQLite
import Foundation

public enum UsageArchiveError: LocalizedError {
  case sqlite(String)

  public var errorDescription: String? {
    switch self {
    case .sqlite(let message): return "Błąd archiwum Tokenozaura: \(message)"
    }
  }
}

public struct UsageArchiveSummary: Equatable, Sendable {
  public let codexTokens: Int64
  public let claudeTokens: Int64
  public let tokenCostUSD: Decimal?
  public let accuracy: MeasurementAccuracy
  public let sessionCount: Int
  public let projectCount: Int
  public let recordCount: Int

  public init(
    codexTokens: Int64,
    claudeTokens: Int64,
    tokenCostUSD: Decimal?,
    accuracy: MeasurementAccuracy,
    sessionCount: Int,
    projectCount: Int,
    recordCount: Int
  ) {
    self.codexTokens = codexTokens
    self.claudeTokens = claudeTokens
    self.tokenCostUSD = tokenCostUSD
    self.accuracy = accuracy
    self.sessionCount = sessionCount
    self.projectCount = projectCount
    self.recordCount = recordCount
  }

  public var totalTokens: Int64 { codexTokens + claudeTokens }

  public func tokens(for provider: Provider) -> Int64 {
    switch provider {
    case .codex: return codexTokens
    case .claude: return claudeTokens
    }
  }
}

public struct UsageArchiveStore: Sendable {
  public let storageURL: URL

  public init(storageURL: URL? = nil) {
    self.storageURL =
      storageURL
      ?? TokenozaurStorageLocation.directoryURL
      .appendingPathComponent("usage-archive.sqlite")
  }

  public func sync(sessions: [ParsedSession], pricing: PricingEngine) throws {
    guard !sessions.isEmpty else { return }
    try withDatabase { database in
      try execute(database, "BEGIN IMMEDIATE TRANSACTION")
      do {
        let sessionStatement = try prepare(database, Self.upsertSessionSQL)
        let deleteRecordsStatement = try prepare(
          database,
          "DELETE FROM usage_records WHERE session_key = ?"
        )
        let recordStatement = try prepare(database, Self.insertRecordSQL)
        defer {
          sqlite3_finalize(sessionStatement)
          sqlite3_finalize(deleteRecordsStatement)
          sqlite3_finalize(recordStatement)
        }

        for session in sessions {
          let sessionKey = Self.sessionKey(for: session.metadata)
          try bindSession(session, key: sessionKey, to: sessionStatement)
          try stepDone(sessionStatement, database: database)
          sqlite3_reset(sessionStatement)
          sqlite3_clear_bindings(sessionStatement)

          try bindText(sessionKey, at: 1, to: deleteRecordsStatement)
          try stepDone(deleteRecordsStatement, database: database)
          sqlite3_reset(deleteRecordsStatement)
          sqlite3_clear_bindings(deleteRecordsStatement)

          let report = pricing.calculate(
            AnalysisResult(root: session.metadata, sessions: [session])
          )
          let costsByRecord = Dictionary(
            report.lines.map { ($0.recordID, $0) },
            uniquingKeysWith: { first, _ in first }
          )
          for record in session.records {
            try bindRecord(
              record,
              sessionKey: sessionKey,
              costLine: costsByRecord[record.id],
              catalogSnapshotID: report.catalogSnapshotID,
              to: recordStatement
            )
            try stepDone(recordStatement, database: database)
            sqlite3_reset(recordStatement)
            sqlite3_clear_bindings(recordStatement)
          }
        }
        try execute(database, "COMMIT")
      } catch {
        try? execute(database, "ROLLBACK")
        throw error
      }
    }
  }

  public func analysis(from start: Date, through end: Date) throws -> AnalysisResult {
    try withDatabase { database in
      let recordStatement = try prepare(database, Self.selectRecordsSQL)
      defer { sqlite3_finalize(recordStatement) }
      sqlite3_bind_double(recordStatement, 1, start.timeIntervalSince1970)
      sqlite3_bind_double(recordStatement, 2, end.timeIntervalSince1970)

      var recordsBySession: [String: [UsageRecord]] = [:]
      while sqlite3_step(recordStatement) == SQLITE_ROW {
        let sessionKey = text(recordStatement, 0) ?? ""
        guard let provider = text(recordStatement, 2).flatMap(Provider.init(rawValue:)),
          let recordID = text(recordStatement, 1),
          let sessionID = text(recordStatement, 3),
          let requestID = text(recordStatement, 6),
          let modelID = text(recordStatement, 8),
          let sourceFile = text(recordStatement, 23)
        else { continue }
        let record = UsageRecord(
          id: recordID,
          provider: provider,
          sessionID: sessionID,
          parentSessionID: text(recordStatement, 4),
          agentID: text(recordStatement, 5),
          requestID: requestID,
          messageID: text(recordStatement, 7),
          modelID: modelID,
          timestamp: Date(timeIntervalSince1970: sqlite3_column_double(recordStatement, 9)),
          usage: UsageBreakdown(
            inputUncached: sqlite3_column_int64(recordStatement, 10),
            inputCachedRead: sqlite3_column_int64(recordStatement, 11),
            cacheWrite5m: sqlite3_column_int64(recordStatement, 12),
            cacheWrite1h: sqlite3_column_int64(recordStatement, 13),
            output: sqlite3_column_int64(recordStatement, 14),
            reasoningOrThinking: sqlite3_column_int64(recordStatement, 15)
          ),
          isSidechain: optionalBool(recordStatement, 16),
          serviceTier: text(recordStatement, 17).flatMap(ServiceTier.init(rawValue:)),
          serviceTierClassificationSource: text(recordStatement, 18)
            .flatMap(ServiceTierClassificationSource.init(rawValue:)),
          serverToolUseCount: Int(sqlite3_column_int64(recordStatement, 19)),
          sourceFile: sourceFile
        )
        recordsBySession[sessionKey, default: []].append(record)
      }

      guard !recordsBySession.isEmpty else {
        return AnalysisResult(root: Self.fallbackMetadata, sessions: [])
      }

      let sessionStatement = try prepare(database, Self.selectSessionsSQL)
      defer { sqlite3_finalize(sessionStatement) }
      sqlite3_bind_double(sessionStatement, 1, start.timeIntervalSince1970)
      sqlite3_bind_double(sessionStatement, 2, end.timeIntervalSince1970)

      var sessions: [ParsedSession] = []
      while sqlite3_step(sessionStatement) == SQLITE_ROW {
        let sessionKey = text(sessionStatement, 0) ?? ""
        guard let provider = text(sessionStatement, 1).flatMap(Provider.init(rawValue:)),
          let sessionID = text(sessionStatement, 2),
          let originator = text(sessionStatement, 6),
          let sourceFile = text(sessionStatement, 10),
          let parserVersion = text(sessionStatement, 15),
          let records = recordsBySession[sessionKey]
        else { continue }
        let startedAt: Date? =
          sqlite3_column_type(sessionStatement, 8) == SQLITE_NULL
          ? nil
          : Date(timeIntervalSince1970: sqlite3_column_double(sessionStatement, 8))
        let warnings: [String] =
          text(sessionStatement, 14)
          .flatMap { $0.data(using: .utf8) }
          .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let metadata = SessionMetadata(
          provider: provider,
          sessionID: sessionID,
          parentSessionID: text(sessionStatement, 3),
          replayParentSessionID: text(sessionStatement, 4),
          replayKind: text(sessionStatement, 5).flatMap(ReplayKind.init(rawValue:)),
          agentID: text(sessionStatement, 7),
          originator: originator,
          appVersion: text(sessionStatement, 9),
          startedAt: startedAt,
          workingDirectory: text(sessionStatement, 11),
          sourceFile: sourceFile,
          isDesktop: sqlite3_column_int(sessionStatement, 12) != 0
        )
        sessions.append(
          ParsedSession(
            metadata: metadata,
            records: records.sorted { $0.timestamp < $1.timestamp },
            toolCallCount: Int(sqlite3_column_int64(sessionStatement, 13)),
            warnings: warnings,
            parserVersion: parserVersion,
            normalizerVersion: text(sessionStatement, 16),
            measurementAccuracy: text(sessionStatement, 17)
              .flatMap(MeasurementAccuracy.init(rawValue:)),
            droppedReplayRecordCount: optionalInt(sessionStatement, 18)
          )
        )
      }
      sessions.sort {
        ($0.metadata.startedAt ?? .distantPast) < ($1.metadata.startedAt ?? .distantPast)
      }
      return AnalysisResult(
        root: sessions.first?.metadata ?? Self.fallbackMetadata, sessions: sessions)
    }
  }

  public func summary(from start: Date, through end: Date) throws -> UsageArchiveSummary {
    try withDatabase { database in
      let statement = try prepare(database, Self.selectSummarySQL)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw UsageArchiveError.sqlite("Nie udało się podsumować archiwum.")
      }

      let recordCount = Int(sqlite3_column_int64(statement, 0))
      let knownCostCount = Int(sqlite3_column_int64(statement, 5))
      let inexactCostCount = Int(sqlite3_column_int64(statement, 7))
      let sourceAccuracy = Int(sqlite3_column_int(statement, 8))
      let accuracy: MeasurementAccuracy
      if recordCount == 0 || knownCostCount == 0 || sourceAccuracy == 2 {
        accuracy = .unavailable
      } else if knownCostCount < recordCount || inexactCostCount > 0 || sourceAccuracy == 1 {
        accuracy = .partial
      } else {
        accuracy = .exact
      }
      let cost =
        knownCostCount == 0
        ? nil
        : Decimal(sqlite3_column_double(statement, 6))

      return UsageArchiveSummary(
        codexTokens: sqlite3_column_int64(statement, 3),
        claudeTokens: sqlite3_column_int64(statement, 4),
        tokenCostUSD: cost,
        accuracy: accuracy,
        sessionCount: Int(sqlite3_column_int64(statement, 1)),
        projectCount: Int(sqlite3_column_int64(statement, 2)),
        recordCount: recordCount
      )
    }
  }

  public func availableYears() throws -> [Int] {
    try withDatabase { database in
      let statement = try prepare(
        database,
        """
        SELECT DISTINCT CAST(strftime('%Y', timestamp, 'unixepoch', 'localtime') AS INTEGER)
        FROM usage_records
        ORDER BY 1 DESC
        """
      )
      defer { sqlite3_finalize(statement) }
      var years: [Int] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        years.append(Int(sqlite3_column_int(statement, 0)))
      }
      return years
    }
  }

  public func recordCount() throws -> Int {
    try withDatabase { database in
      let statement = try prepare(database, "SELECT COUNT(*) FROM usage_records")
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  public func needsRepricing(for catalogSnapshotID: String) throws -> Bool {
    try withDatabase { database in
      let statement = try prepare(
        database,
        "SELECT EXISTS(SELECT 1 FROM usage_records WHERE pricing_snapshot != ? LIMIT 1)"
      )
      defer { sqlite3_finalize(statement) }
      try bindText(catalogSnapshotID, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return false }
      return sqlite3_column_int(statement, 0) != 0
    }
  }

  public func storedCostUSD(from start: Date, through end: Date) throws -> Decimal? {
    try withDatabase { database in
      let statement = try prepare(
        database,
        """
        SELECT cost_usd
        FROM usage_records
        WHERE timestamp >= ? AND timestamp <= ? AND cost_usd IS NOT NULL
        """
      )
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
      sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
      var amounts: [Decimal] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        if let value = text(statement, 0).flatMap({ Decimal(string: $0) }) {
          amounts.append(value)
        }
      }
      return amounts.isEmpty ? nil : amounts.reduce(Decimal.zero, +)
    }
  }

  private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: storageURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(storageURL.path, &database, flags, nil) == SQLITE_OK,
      let database
    else {
      let message =
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Nie można otworzyć bazy."
      if let database { sqlite3_close(database) }
      throw UsageArchiveError.sqlite(message)
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5_000)
    try execute(database, "PRAGMA journal_mode = WAL")
    try execute(database, "PRAGMA foreign_keys = ON")
    try migrate(database)
    return try body(database)
  }

  private func migrate(_ database: OpaquePointer) throws {
    let version = try databaseVersion(database)
    if version == 0 {
      try execute(database, Self.schemaSQL)
      try execute(database, "PRAGMA user_version = 2")
      return
    }
    if version == 1 {
      try execute(database, "BEGIN IMMEDIATE TRANSACTION")
      do {
        try execute(database, Self.migrateUsageRecordsToCompositeKeySQL)
        try execute(database, "PRAGMA user_version = 2")
        try execute(database, "COMMIT")
      } catch {
        try? execute(database, "ROLLBACK")
        throw error
      }
      return
    }
    try execute(database, Self.schemaSQL)
  }

  private func databaseVersion(_ database: OpaquePointer) throws -> Int {
    let statement = try prepare(database, "PRAGMA user_version")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw UsageArchiveError.sqlite("Nie udało się odczytać wersji bazy.")
    }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func execute(_ database: OpaquePointer, _ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(errorMessage)
      throw UsageArchiveError.sqlite(message)
    }
  }

  private func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw UsageArchiveError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    return statement
  }

  private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw UsageArchiveError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
  }

  private func bindSession(_ session: ParsedSession, key: String, to statement: OpaquePointer)
    throws
  {
    let metadata = session.metadata
    let warningsData = try JSONEncoder().encode(session.warnings)
    let warnings = String(data: warningsData, encoding: .utf8) ?? "[]"
    try bindText(key, at: 1, to: statement)
    try bindText(metadata.provider.rawValue, at: 2, to: statement)
    try bindText(metadata.sessionID, at: 3, to: statement)
    try bindText(metadata.parentSessionID, at: 4, to: statement)
    try bindText(metadata.replayParentSessionID, at: 5, to: statement)
    try bindText(metadata.replayKind?.rawValue, at: 6, to: statement)
    try bindText(metadata.originator, at: 7, to: statement)
    try bindText(metadata.agentID, at: 8, to: statement)
    bindDate(metadata.startedAt, at: 9, to: statement)
    try bindText(metadata.appVersion, at: 10, to: statement)
    try bindText(metadata.sourceFile, at: 11, to: statement)
    try bindText(metadata.workingDirectory, at: 12, to: statement)
    sqlite3_bind_int(statement, 13, metadata.isDesktop ? 1 : 0)
    sqlite3_bind_int64(statement, 14, Int64(session.toolCallCount))
    try bindText(warnings, at: 15, to: statement)
    try bindText(session.parserVersion, at: 16, to: statement)
    try bindText(session.normalizerVersion, at: 17, to: statement)
    try bindText(session.measurementAccuracy?.rawValue, at: 18, to: statement)
    bindInt(session.droppedReplayRecordCount, at: 19, to: statement)
    sqlite3_bind_double(statement, 20, Date().timeIntervalSince1970)
  }

  private func bindRecord(
    _ record: UsageRecord,
    sessionKey: String,
    costLine: CostLine?,
    catalogSnapshotID: String,
    to statement: OpaquePointer
  ) throws {
    try bindText(record.id, at: 1, to: statement)
    try bindText(sessionKey, at: 2, to: statement)
    try bindText(record.provider.rawValue, at: 3, to: statement)
    try bindText(record.sessionID, at: 4, to: statement)
    try bindText(record.parentSessionID, at: 5, to: statement)
    try bindText(record.agentID, at: 6, to: statement)
    try bindText(record.requestID, at: 7, to: statement)
    try bindText(record.messageID, at: 8, to: statement)
    try bindText(record.modelID, at: 9, to: statement)
    sqlite3_bind_double(statement, 10, record.timestamp.timeIntervalSince1970)
    sqlite3_bind_int64(statement, 11, record.usage.inputUncached)
    sqlite3_bind_int64(statement, 12, record.usage.inputCachedRead)
    sqlite3_bind_int64(statement, 13, record.usage.cacheWrite5m)
    sqlite3_bind_int64(statement, 14, record.usage.cacheWrite1h)
    sqlite3_bind_int64(statement, 15, record.usage.output)
    sqlite3_bind_int64(statement, 16, record.usage.reasoningOrThinking)
    bindBool(record.isSidechain, at: 17, to: statement)
    try bindText(record.serviceTier?.rawValue, at: 18, to: statement)
    try bindText(record.serviceTierClassificationSource?.rawValue, at: 19, to: statement)
    sqlite3_bind_int64(statement, 20, Int64(record.serverToolUseCount))
    try bindText(record.sourceFile, at: 21, to: statement)
    try bindText(
      costLine?.amountUSD.map { NSDecimalNumber(decimal: $0).stringValue }, at: 22, to: statement)
    try bindText(costLine?.accuracy.rawValue, at: 23, to: statement)
    try bindText(catalogSnapshotID, at: 24, to: statement)
  }

  private func bindText(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, Self.transientDestructor)
    }
    guard result == SQLITE_OK else {
      throw UsageArchiveError.sqlite("Nie udało się zapisać tekstu w bazie.")
    }
  }

  private func bindDate(_ value: Date?, at index: Int32, to statement: OpaquePointer) {
    if let value {
      sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func bindInt(_ value: Int?, at index: Int32, to statement: OpaquePointer) {
    if let value {
      sqlite3_bind_int64(statement, index, Int64(value))
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func bindBool(_ value: Bool?, at index: Int32, to statement: OpaquePointer) {
    if let value {
      sqlite3_bind_int(statement, index, value ? 1 : 0)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, column)
    else { return nil }
    return String(cString: pointer)
  }

  private func optionalBool(_ statement: OpaquePointer, _ column: Int32) -> Bool? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return sqlite3_column_int(statement, column) != 0
  }

  private func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(statement, column))
  }

  private static func sessionKey(for metadata: SessionMetadata) -> String {
    "\(metadata.provider.rawValue):\(metadata.sourceFile)"
  }

  private static let fallbackMetadata = SessionMetadata(
    provider: .codex,
    sessionID: "usage-archive",
    originator: "tokenozaur",
    sourceFile: "usage-archive.sqlite",
    isDesktop: true
  )

  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS sessions (
        session_key TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        session_id TEXT NOT NULL,
        parent_session_id TEXT,
        replay_parent_session_id TEXT,
        replay_kind TEXT,
        originator TEXT NOT NULL,
        agent_id TEXT,
        started_at REAL,
        app_version TEXT,
        source_file TEXT NOT NULL,
        working_directory TEXT,
        is_desktop INTEGER NOT NULL,
        tool_call_count INTEGER NOT NULL,
        warnings_json TEXT NOT NULL,
        parser_version TEXT NOT NULL,
        normalizer_version TEXT,
        measurement_accuracy TEXT,
        dropped_replay_records INTEGER,
        last_seen_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS usage_records (
        record_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        provider TEXT NOT NULL,
        session_id TEXT NOT NULL,
        parent_session_id TEXT,
        agent_id TEXT,
        request_id TEXT NOT NULL,
        message_id TEXT,
        model_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        input_uncached INTEGER NOT NULL,
        input_cached_read INTEGER NOT NULL,
        cache_write_5m INTEGER NOT NULL,
        cache_write_1h INTEGER NOT NULL,
        output INTEGER NOT NULL,
        reasoning_or_thinking INTEGER NOT NULL,
        is_sidechain INTEGER,
        service_tier TEXT,
        tier_source TEXT,
        server_tool_use_count INTEGER NOT NULL,
        source_file TEXT NOT NULL,
        cost_usd TEXT,
        cost_accuracy TEXT,
        pricing_snapshot TEXT NOT NULL,
        PRIMARY KEY(session_key, record_id),
        FOREIGN KEY(session_key) REFERENCES sessions(session_key) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS usage_records_timestamp ON usage_records(timestamp);
    CREATE INDEX IF NOT EXISTS usage_records_session ON usage_records(session_key);
    CREATE INDEX IF NOT EXISTS usage_records_provider ON usage_records(provider);
    """

  private static let migrateUsageRecordsToCompositeKeySQL = """
    ALTER TABLE usage_records RENAME TO usage_records_v1;
    CREATE TABLE usage_records (
        record_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        provider TEXT NOT NULL,
        session_id TEXT NOT NULL,
        parent_session_id TEXT,
        agent_id TEXT,
        request_id TEXT NOT NULL,
        message_id TEXT,
        model_id TEXT NOT NULL,
        timestamp REAL NOT NULL,
        input_uncached INTEGER NOT NULL,
        input_cached_read INTEGER NOT NULL,
        cache_write_5m INTEGER NOT NULL,
        cache_write_1h INTEGER NOT NULL,
        output INTEGER NOT NULL,
        reasoning_or_thinking INTEGER NOT NULL,
        is_sidechain INTEGER,
        service_tier TEXT,
        tier_source TEXT,
        server_tool_use_count INTEGER NOT NULL,
        source_file TEXT NOT NULL,
        cost_usd TEXT,
        cost_accuracy TEXT,
        pricing_snapshot TEXT NOT NULL,
        PRIMARY KEY(session_key, record_id),
        FOREIGN KEY(session_key) REFERENCES sessions(session_key) ON DELETE CASCADE
    );
    INSERT INTO usage_records (
        record_id, session_key, provider, session_id, parent_session_id, agent_id,
        request_id, message_id, model_id, timestamp, input_uncached, input_cached_read,
        cache_write_5m, cache_write_1h, output, reasoning_or_thinking, is_sidechain,
        service_tier, tier_source, server_tool_use_count, source_file, cost_usd,
        cost_accuracy, pricing_snapshot
    )
    SELECT
        record_id, session_key, provider, session_id, parent_session_id, agent_id,
        request_id, message_id, model_id, timestamp, input_uncached, input_cached_read,
        cache_write_5m, cache_write_1h, output, reasoning_or_thinking, is_sidechain,
        service_tier, tier_source, server_tool_use_count, source_file, cost_usd,
        cost_accuracy, pricing_snapshot
    FROM usage_records_v1;
    DROP TABLE usage_records_v1;
    CREATE INDEX usage_records_timestamp ON usage_records(timestamp);
    CREATE INDEX usage_records_session ON usage_records(session_key);
    CREATE INDEX usage_records_provider ON usage_records(provider);
    """

  private static let upsertSessionSQL = """
    INSERT INTO sessions (
        session_key, provider, session_id, parent_session_id, replay_parent_session_id,
        replay_kind, originator, agent_id, started_at, app_version, source_file,
        working_directory, is_desktop, tool_call_count, warnings_json, parser_version,
        normalizer_version, measurement_accuracy, dropped_replay_records, last_seen_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(session_key) DO UPDATE SET
        provider = excluded.provider,
        session_id = excluded.session_id,
        parent_session_id = excluded.parent_session_id,
        replay_parent_session_id = excluded.replay_parent_session_id,
        replay_kind = excluded.replay_kind,
        originator = excluded.originator,
        agent_id = excluded.agent_id,
        started_at = excluded.started_at,
        app_version = excluded.app_version,
        source_file = excluded.source_file,
        working_directory = excluded.working_directory,
        is_desktop = excluded.is_desktop,
        tool_call_count = excluded.tool_call_count,
        warnings_json = excluded.warnings_json,
        parser_version = excluded.parser_version,
        normalizer_version = excluded.normalizer_version,
        measurement_accuracy = excluded.measurement_accuracy,
        dropped_replay_records = excluded.dropped_replay_records,
        last_seen_at = excluded.last_seen_at
    """

  private static let insertRecordSQL = """
    INSERT INTO usage_records (
        record_id, session_key, provider, session_id, parent_session_id, agent_id,
        request_id, message_id, model_id, timestamp, input_uncached, input_cached_read,
        cache_write_5m, cache_write_1h, output, reasoning_or_thinking, is_sidechain,
        service_tier, tier_source, server_tool_use_count, source_file, cost_usd,
        cost_accuracy, pricing_snapshot
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

  private static let selectRecordsSQL = """
    SELECT session_key, record_id, provider, session_id, parent_session_id, agent_id,
           request_id, message_id, model_id, timestamp, input_uncached, input_cached_read,
           cache_write_5m, cache_write_1h, output, reasoning_or_thinking, is_sidechain,
           service_tier, tier_source, server_tool_use_count, cost_usd, cost_accuracy,
           pricing_snapshot, source_file
    FROM usage_records
    WHERE timestamp >= ? AND timestamp <= ?
    ORDER BY timestamp, record_id
    """

  private static let selectSessionsSQL = """
    SELECT DISTINCT s.session_key, s.provider, s.session_id, s.parent_session_id,
           s.replay_parent_session_id, s.replay_kind, s.originator, s.agent_id,
           s.started_at, s.app_version, s.source_file, s.working_directory,
           s.is_desktop, s.tool_call_count, s.warnings_json, s.parser_version,
           s.normalizer_version, s.measurement_accuracy, s.dropped_replay_records
    FROM sessions s
    JOIN usage_records r ON r.session_key = s.session_key
    WHERE r.timestamp >= ? AND r.timestamp <= ?
    ORDER BY s.started_at, s.session_key
    """

  private static let selectSummarySQL = """
    SELECT
        COUNT(*),
        COUNT(DISTINCT r.session_key),
        COUNT(DISTINCT CASE
            WHEN s.working_directory IS NOT NULL AND s.working_directory != ''
            THEN s.working_directory END),
        COALESCE(SUM(CASE WHEN r.provider = 'codex' THEN
            r.input_uncached + r.input_cached_read + r.cache_write_5m +
            r.cache_write_1h + r.output ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN r.provider = 'claude' THEN
            r.input_uncached + r.input_cached_read + r.cache_write_5m +
            r.cache_write_1h + r.output ELSE 0 END), 0),
        SUM(CASE WHEN r.cost_usd IS NOT NULL THEN 1 ELSE 0 END),
        COALESCE(SUM(CAST(r.cost_usd AS REAL)), 0),
        SUM(CASE WHEN r.cost_usd IS NOT NULL AND r.cost_accuracy != 'exact' THEN 1 ELSE 0 END),
        COALESCE(MAX(CASE s.measurement_accuracy
            WHEN 'unavailable' THEN 2
            WHEN 'partial' THEN 1
            ELSE 0 END), 0)
    FROM usage_records r
    JOIN sessions s ON s.session_key = r.session_key
    WHERE r.timestamp >= ? AND r.timestamp <= ?
    """
}
