import Darwin
import Foundation
import TokenozaurCore

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  if condition() {
    print("PASS  \(name)")
  } else {
    print("FAIL  \(name)")
    failures.append(name)
  }
}

private func fixture(_ name: String) -> URL {
  guard
    let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures")
  else {
    fatalError("Missing fixture: \(name)")
  }
  return url
}

private func fixtureFile(_ name: String, extension fileExtension: String) -> URL {
  guard
    let url = Bundle.module.url(
      forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
  else {
    fatalError("Missing fixture: \(name).\(fileExtension)")
  }
  return url
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

do {
  let migrationRoot = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: migrationRoot) }
  let legacyStorage = migrationRoot.appendingPathComponent("Tokenozerca", isDirectory: true)
  try FileManager.default.createDirectory(at: legacyStorage, withIntermediateDirectories: true)
  try Data("history".utf8).write(to: legacyStorage.appendingPathComponent("marker"))
  let migratedStorage = TokenozaurStorageLocation.resolve(in: migrationRoot)
  check(
    migratedStorage.lastPathComponent == "Tokenozaur"
      && FileManager.default.fileExists(
        atPath: migratedStorage.appendingPathComponent("marker").path)
      && !FileManager.default.fileExists(atPath: legacyStorage.path),
    "Legacy Tokenożerca storage migrates without data loss"
  )

  let codex = try CodexLogAdapter().parse(at: fixture("codex-root"), defaultServiceTier: .standard)
  check(codex.metadata.sessionID == "codex-root", "Codex metadata")
  check(codex.metadata.isDesktop, "Codex desktop originator")
  check(codex.records.count == 2, "Codex deduplicates cumulative snapshots")
  check(codex.toolCallCount == 1, "Codex tool calls")
  check(
    codex.totalUsage
      == UsageBreakdown(
        inputUncached: 140,
        inputCachedRead: 100,
        cacheWrite5m: 10,
        output: 25,
        reasoningOrThinking: 5
      ), "Codex cumulative delta math")
  check(codex.parserVersion == "codex-jsonl-v2", "Codex parser version is auditable")
  check(
    codex.records.allSatisfy {
      $0.serviceTier == .standard && $0.serviceTierClassificationSource == .configuration
    }, "Codex config tier fallback")

  let codexChild = try CodexLogAdapter().parse(at: fixture("codex-child"))
  check(codexChild.metadata.parentSessionID == "codex-root", "Codex child relation")
  check(codexChild.totalUsage.inputUncached == 40, "Codex child usage")

  let codexGuardian = try CodexLogAdapter().parse(at: fixture("codex-guardian"))
  check(codexGuardian.metadata.parentSessionID == "codex-root", "Codex direct parent relation")
  check(codexGuardian.metadata.agentID == "guardian", "Codex guardian classification")
  check(
    codexGuardian.metadata.replayParentSessionID == nil,
    "Codex guardian is not classified as replay fork")

  let codexReplayChild = try CodexLogAdapter().parse(
    at: fixture("codex-replay-child"), defaultServiceTier: .standard)
  check(
    codexReplayChild.metadata.replayParentSessionID == "codex-root",
    "Codex replay parent provenance")
  let replayNormalized = UsageNormalizer().normalize([codex, codexReplayChild])
  let replayAnalysis = AnalysisResult(root: codex.metadata, sessions: replayNormalized)
  check(replayNormalized[1].records.count == 1, "Codex drops matching parent replay prefix")
  check(
    replayNormalized[1].records.first?.requestID == "child-work", "Codex keeps child-owned work")
  check(replayAnalysis.totalUsage.total == 353, "Codex replay is counted exactly once")
  check(replayNormalized[1].droppedReplayRecordCount == 2, "Codex reports dropped replay records")

  let nestedChild = try CodexLogAdapter().parse(
    at: fixture("codex-nested-child"), defaultServiceTier: .standard)
  let nestedNormalized = UsageNormalizer().normalize([codex, codexReplayChild, nestedChild])
  check(nestedNormalized[2].records.count == 1, "Nested Codex child keeps unique work")
  check(
    AnalysisResult(root: codex.metadata, sessions: nestedNormalized).totalUsage.total == 382,
    "Nested Codex graph has no double count")

  let legacyReplay = try CodexLogAdapter().parse(
    at: fixture("codex-legacy-replay"), defaultServiceTier: .standard)
  let legacyNormalized = UsageNormalizer().normalize([legacyReplay])
  check(legacyNormalized[0].records.count == 1, "Legacy dense replay burst is removed")
  check(legacyNormalized[0].measurementAccuracy == .partial, "Heuristic replay is marked partial")

  let missingParentMetadata = SessionMetadata(
    provider: .codex, sessionID: "legacy-no-parent", parentSessionID: "missing",
    replayParentSessionID: "missing", replayKind: .legacyFork, originator: "Codex Desktop",
    sourceFile: "/tmp/legacy-no-parent", isDesktop: true)
  let missingParentRecord = UsageRecord(
    id: "legacy-own-or-replay", provider: .codex, sessionID: "legacy-no-parent",
    parentSessionID: "missing", requestID: "one", modelID: "gpt-5.6-sol", timestamp: Date(),
    usage: UsageBreakdown(inputUncached: 10, output: 1), serviceTier: .standard,
    sourceFile: "/tmp/legacy-no-parent")
  let missingParentSession = ParsedSession(
    metadata: missingParentMetadata, records: [missingParentRecord], parserVersion: "test")
  let missingParentNormalized = UsageNormalizer().normalize([missingParentSession])
  check(
    missingParentNormalized[0].records.count == 1
      && missingParentNormalized[0].measurementAccuracy == .partial,
    "Unverifiable legacy fork stays visible but partial")
  check(
    PricingEngine().calculate(
      AnalysisResult(root: missingParentMetadata, sessions: missingParentNormalized)
    ).accuracy == .partial, "Parser uncertainty propagates to cost report")

  let claude = try ClaudeLogAdapter().parse(at: fixture("claude-root"))
  check(claude.metadata.sessionID == "claude-root", "Claude metadata")
  check(claude.metadata.isDesktop, "Claude desktop entrypoint")
  let claudeCLIMetadata = SessionMetadata(
    provider: .claude, sessionID: "claude-cli", originator: "cli", sourceFile: "/tmp/claude-cli",
    isDesktop: false)
  let claudeSDKMetadata = SessionMetadata(
    provider: .claude, sessionID: "claude-sdk", originator: "sdk-cli",
    sourceFile: "/tmp/claude-sdk", isDesktop: false)
  let codexCLIMetadata = SessionMetadata(
    provider: .codex, sessionID: "codex-cli", originator: "codex_cli_rs",
    sourceFile: "/tmp/codex-cli", isDesktop: false)
  let codexExecMetadata = SessionMetadata(
    provider: .codex, sessionID: "codex-exec", originator: "codex_exec",
    sourceFile: "/tmp/codex-exec", isDesktop: false)
  check(
    claudeCLIMetadata.isInteractive && claudeCLIMetadata.sourceDisplayName == "CLI",
    "Claude CLI is interactive")
  check(!claudeSDKMetadata.isInteractive, "Claude SDK automation is excluded")
  check(
    codexCLIMetadata.isInteractive && codexCLIMetadata.sourceDisplayName == "CLI",
    "Codex CLI is interactive")
  check(!codexExecMetadata.isInteractive, "Codex exec automation is excluded")
  check(claude.records.count == 2, "Claude message deduplication")
  check(claude.toolCallCount == 1, "Claude deduplicated tool calls")
  check(
    claude.totalUsage
      == UsageBreakdown(
        inputUncached: 15,
        inputCachedRead: 100,
        cacheWrite5m: 20,
        cacheWrite1h: 40,
        output: 42,
        reasoningOrThinking: 5
      ), "Claude cache classification")
  check(
    claude.records.allSatisfy { $0.messageID != nil && $0.isSidechain == false },
    "Claude message provenance")

  let claudeChild = try ClaudeLogAdapter().parse(
    at: fixture("claude-child"), rootSessionID: "claude-root")
  check(claudeChild.metadata.parentSessionID == "claude-root", "Claude child relation")

  let claudeReplayChild = try ClaudeLogAdapter().parse(
    at: fixture("claude-sidechain-replay"), rootSessionID: "claude-root")
  let claudeNormalized = UsageNormalizer().normalize([claude, claudeReplayChild])
  let claudeReplayAnalysis = AnalysisResult(root: claude.metadata, sessions: claudeNormalized)
  check(claudeNormalized[1].records.count == 1, "Claude drops parent message copied into sidechain")
  check(claudeReplayAnalysis.totalUsage.output == 57, "Claude keeps unique sidechain response once")

  let otherClaudeMetadata = SessionMetadata(
    provider: .claude, sessionID: "another-root", originator: "claude-desktop",
    sourceFile: "/tmp/other", isDesktop: true)
  let sameMessageDifferentRoot = UsageRecord(
    id: "other-m2", provider: .claude, sessionID: "another-root", requestID: "other",
    messageID: "m2", modelID: "claude-opus-5", timestamp: Date(),
    usage: UsageBreakdown(inputUncached: 7, output: 3), isSidechain: false, sourceFile: "/tmp/other"
  )
  let otherClaudeSession = ParsedSession(
    metadata: otherClaudeMetadata, records: [sameMessageDifferentRoot], parserVersion: "test")
  let collisionNormalized = UsageNormalizer().normalize([claude, otherClaudeSession])
  check(
    collisionNormalized.flatMap(\.records).contains(where: { $0.id == "other-m2" }),
    "Claude message IDs do not collide across roots")

  let codexTemporary = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: codexTemporary) }
  let codexRoot = codexTemporary.appendingPathComponent("codex")
  let emptyClaudeRoot = codexTemporary.appendingPathComponent("claude")
  try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: emptyClaudeRoot, withIntermediateDirectories: true)
  let codexRootFile = codexRoot.appendingPathComponent("root.jsonl")
  try FileManager.default.copyItem(at: fixture("codex-root"), to: codexRootFile)
  try FileManager.default.copyItem(
    at: fixture("codex-child"), to: codexRoot.appendingPathComponent("child.jsonl"))
  let codexAnalysis = try SessionAnalyzer(
    discovery: SessionDiscovery(codexRoot: codexRoot, claudeRoot: emptyClaudeRoot)
  ).analyze(rootURL: codexRootFile, provider: .codex)
  check(codexAnalysis.sessions.count == 2, "Codex descendant discovery")
  check(codexAnalysis.totalUsage.total == 330, "Codex graph aggregation")

  let archiveRoot = codexTemporary.appendingPathComponent("archive")
  try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
  try FileManager.default.copyItem(
    at: fixture("codex-root"), to: archiveRoot.appendingPathComponent("root-copy.jsonl"))
  try FileManager.default.copyItem(
    at: fixture("codex-tier"), to: archiveRoot.appendingPathComponent("archive-only.jsonl"))
  let archiveDiscovery = SessionDiscovery(
    codexRoot: codexRoot, codexArchiveRoot: archiveRoot, claudeRoot: emptyClaudeRoot)
  let dedupedFiles = archiveDiscovery.allInteractiveSessionFiles(provider: .codex)
  check(
    dedupedFiles.filter { $0.metadata.sessionID == "codex-root" }.count == 1,
    "Active/archive duplicate is counted once")
  check(
    dedupedFiles.first(where: { $0.metadata.sessionID == "codex-root" })?.url.path.contains(
      "/codex/") == true, "Active Codex file wins archive duplicate")
  check(
    dedupedFiles.contains(where: { $0.metadata.sessionID == "codex-tier" }),
    "Archive-only Codex session remains visible")

  let mixedActive = codexTemporary.appendingPathComponent("mixed-active")
  let mixedArchive = codexTemporary.appendingPathComponent("mixed-archive")
  try FileManager.default.createDirectory(at: mixedActive, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: mixedArchive, withIntermediateDirectories: true)
  let mixedRootFile = mixedActive.appendingPathComponent("root.jsonl")
  try FileManager.default.copyItem(at: fixture("codex-root"), to: mixedRootFile)
  try FileManager.default.copyItem(
    at: fixture("codex-child"), to: mixedArchive.appendingPathComponent("child.jsonl"))
  let mixedAnalysis = try SessionAnalyzer(
    discovery: SessionDiscovery(
      codexRoot: mixedActive, codexArchiveRoot: mixedArchive, claudeRoot: emptyClaudeRoot)
  ).analyze(rootURL: mixedRootFile, provider: .codex)
  check(mixedAnalysis.sessions.count == 2, "Codex parent-child graph spans active and archive")

  let archiveGraphRoot = mixedArchive.appendingPathComponent("root.jsonl")
  try FileManager.default.copyItem(at: fixture("codex-root"), to: archiveGraphRoot)
  let archiveGraphAnalysis = try SessionAnalyzer(
    discovery: SessionDiscovery(
      codexRoot: codexTemporary.appendingPathComponent("empty-active"),
      codexArchiveRoot: mixedArchive, claudeRoot: emptyClaudeRoot)
  ).analyze(rootURL: archiveGraphRoot, provider: .codex)
  check(archiveGraphAnalysis.sessions.count == 2, "Codex parent-child graph works fully in archive")

  let claudeTemporary = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: claudeTemporary) }
  let emptyCodexRoot = claudeTemporary.appendingPathComponent("codex")
  let claudeRoot = claudeTemporary.appendingPathComponent("claude/project")
  try FileManager.default.createDirectory(at: emptyCodexRoot, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
  let claudeRootFile = claudeRoot.appendingPathComponent("claude-root.jsonl")
  try FileManager.default.copyItem(at: fixture("claude-root"), to: claudeRootFile)
  try Data(
    "{\"sessionId\":\"claude-cli\",\"entrypoint\":\"cli\",\"timestamp\":\"2026-09-02T11:00:00.000Z\",\"cwd\":\"/tmp/cli\",\"type\":\"user\"}\n"
      .utf8
  )
  .write(to: claudeRoot.appendingPathComponent("claude-cli.jsonl"))
  try Data(
    "{\"sessionId\":\"claude-sdk\",\"entrypoint\":\"sdk-cli\",\"timestamp\":\"2026-09-02T11:00:00.000Z\",\"cwd\":\"/tmp/sdk\",\"type\":\"user\"}\n"
      .utf8
  )
  .write(to: claudeRoot.appendingPathComponent("claude-sdk.jsonl"))
  let subagents = claudeRoot.appendingPathComponent("claude-root/subagents")
  try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
  try FileManager.default.copyItem(
    at: fixture("claude-child"), to: subagents.appendingPathComponent("child.jsonl"))
  let claudeAnalysis = try SessionAnalyzer(
    discovery: SessionDiscovery(
      codexRoot: emptyCodexRoot, claudeRoot: claudeTemporary.appendingPathComponent("claude"))
  ).analyze(rootURL: claudeRootFile, provider: .claude)
  check(claudeAnalysis.sessions.count == 2, "Claude subagent discovery")
  check(claudeAnalysis.totalUsage.output == 57, "Claude graph aggregation")
  let interactiveClaudeFiles = SessionDiscovery(
    codexRoot: emptyCodexRoot,
    claudeRoot: claudeTemporary.appendingPathComponent("claude")
  ).allInteractiveSessionFiles(provider: .claude)
  check(
    interactiveClaudeFiles.contains(where: { $0.metadata.sessionID == "claude-cli" }),
    "Claude CLI appears in interactive history")
  check(
    !interactiveClaudeFiles.contains(where: { $0.metadata.sessionID == "claude-sdk" }),
    "Claude SDK stays out of interactive history")

  let codexTitleIndexURL = claudeTemporary.appendingPathComponent("session-index.jsonl")
  let claudeHistoryURL = claudeTemporary.appendingPathComponent("history.jsonl")
  try Data("{\"id\":\"codex-root\",\"thread_name\":\"  Build   Tokenozaur  \"}\n".utf8)
    .write(to: codexTitleIndexURL)
  try Data(
    "{\"sessionId\":\"claude-root\",\"display\":\"Pierwszy   prompt do aplikacji\",\"timestamp\":200}\n{\"sessionId\":\"claude-root\",\"display\":\"Jeszcze wcześniejszy prompt\",\"timestamp\":100}\n"
      .utf8
  )
  .write(to: claudeHistoryURL)
  let titleIndex = SessionTitleIndex(
    codexIndexURL: codexTitleIndexURL,
    claudeHistoryURL: claudeHistoryURL
  )
  check(
    titleIndex.titles(for: .codex)["codex-root"] == "Build Tokenozaur", "Codex thread title index")
  check(
    titleIndex.titles(for: .claude)["claude-root"] == "Jeszcze wcześniejszy prompt",
    "Claude first prompt title fallback")
  let historyCacheURL = claudeTemporary.appendingPathComponent("session-history-cache.json")
  let historyCacheStore = SessionHistoryCacheStore(storageURL: historyCacheURL)
  let cachedCandidate = SessionCandidate(
    url: codexRootFile,
    metadata: codex.metadata,
    modifiedAt: Date(timeIntervalSince1970: 1234),
    threadName: "Build Tokenozaur"
  )
  try historyCacheStore.save([
    cachedCandidate.id: CachedSessionSnapshot(candidate: cachedCandidate, session: codex)
  ])
  let loadedHistoryCache = historyCacheStore.load()
  check(
    loadedHistoryCache[cachedCandidate.id]?.session.totalUsage == codex.totalUsage
      && loadedHistoryCache[cachedCandidate.id]?.candidate.modifiedAt == cachedCandidate.modifiedAt,
    "Period history cache round-trip"
  )
  let archivedSourceURL = claudeTemporary.appendingPathComponent("archive-source.jsonl")
  try FileManager.default.copyItem(at: fixture("codex-root"), to: archivedSourceURL)
  let archivedSession = try CodexLogAdapter().parse(
    at: archivedSourceURL, defaultServiceTier: .standard)
  let usageArchive = UsageArchiveStore(
    storageURL: claudeTemporary.appendingPathComponent("usage-archive.sqlite")
  )
  let archivePricing = PricingEngine()
  try usageArchive.sync(sessions: [archivedSession], pricing: archivePricing)
  let currentPricingNeedsRefresh = try usageArchive.needsRepricing(
    for: archivePricing.catalog.snapshotID
  )
  let futurePricingNeedsRefresh = try usageArchive.needsRepricing(
    for: "future-pricing-snapshot"
  )
  check(
    !currentPricingNeedsRefresh && futurePricingNeedsRefresh,
    "Usage archive detects pricing snapshot changes"
  )
  try FileManager.default.removeItem(at: archivedSourceURL)
  let archivedAnalysis = try usageArchive.analysis(
    from: Date(timeIntervalSince1970: 0),
    through: .distantFuture
  )
  let firstArchivedRecordCount = try usageArchive.recordCount()
  check(firstArchivedRecordCount == 2, "Usage archive stores records without transcript content")
  let firstArchivedSummary = try usageArchive.summary(
    from: Date(timeIntervalSince1970: 0),
    through: .distantFuture
  )
  check(
    firstArchivedSummary.recordCount == 2 && firstArchivedSummary.sessionCount == 1
      && firstArchivedSummary.totalTokens == archivedSession.totalUsage.total
      && firstArchivedSummary.accuracy == .exact,
    "Usage archive summarizes without retaining full records"
  )
  check(
    archivedAnalysis.totalUsage == archivedSession.totalUsage
      && archivedAnalysis.sessions.first?.metadata.workingDirectory
        == archivedSession.metadata.workingDirectory,
    "Usage archive survives source transcript deletion"
  )
  let archivedCost = try usageArchive.storedCostUSD(
    from: Date(timeIntervalSince1970: 0),
    through: .distantFuture
  )
  check(
    archivedCost == archivePricing.calculate(archivedAnalysis).tokenCostUSD,
    "Usage archive preserves API-equivalent cost")
  let collidingMetadata = SessionMetadata(
    provider: archivedSession.metadata.provider,
    sessionID: archivedSession.metadata.sessionID,
    originator: archivedSession.metadata.originator,
    startedAt: archivedSession.metadata.startedAt,
    workingDirectory: archivedSession.metadata.workingDirectory,
    sourceFile: "/tmp/colliding-codex-child.jsonl",
    isDesktop: archivedSession.metadata.isDesktop
  )
  let originalRecord = archivedSession.records[0]
  let collidingRecord = UsageRecord(
    id: originalRecord.id,
    provider: originalRecord.provider,
    sessionID: originalRecord.sessionID,
    requestID: "colliding-child-request",
    modelID: originalRecord.modelID,
    timestamp: originalRecord.timestamp,
    usage: originalRecord.usage,
    serviceTier: originalRecord.serviceTier,
    serviceTierClassificationSource: originalRecord.serviceTierClassificationSource,
    sourceFile: collidingMetadata.sourceFile
  )
  let collidingSession = ParsedSession(
    metadata: collidingMetadata,
    records: [collidingRecord],
    parserVersion: "test"
  )
  try usageArchive.sync(sessions: [archivedSession, collidingSession], pricing: archivePricing)
  let resyncedRecordCount = try usageArchive.recordCount()
  let archivedYears = try usageArchive.availableYears()
  check(resyncedRecordCount == 3, "Usage archive permits source-scoped record identifiers")
  try usageArchive.sync(sessions: [archivedSession, collidingSession], pricing: archivePricing)
  let secondResyncRecordCount = try usageArchive.recordCount()
  check(
    secondResyncRecordCount == 3 && archivedYears == [2026],
    "Usage archive upserts without duplicates and groups years")
  let titledDiscovery = SessionDiscovery(
    codexRoot: codexRoot,
    codexArchiveRoot: archiveRoot,
    claudeRoot: claudeTemporary.appendingPathComponent("claude"),
    titleIndex: titleIndex
  )
  check(
    titledDiscovery.recentInteractiveSessions(provider: .codex).first(where: {
      $0.metadata.sessionID == "codex-root"
    })?.displayName == "Build Tokenozaur", "Session displays thread title")

  let damagedFile = claudeTemporary.appendingPathComponent("damaged.jsonl")
  try Data("{\"valid\":true}\n{\"unfinished\":".utf8).write(to: damagedFile)
  var validDamagedObjects = 0
  let damagedSummary = try JSONLReader.forEachObject(at: damagedFile) { _, _ in
    validDamagedObjects += 1
  }
  check(
    validDamagedObjects == 1 && damagedSummary.invalidLines == 1,
    "Damaged JSONL line is reported and skipped")

  let oversizedFile = claudeTemporary.appendingPathComponent("oversized-line.jsonl")
  let oversizedPayload = String(repeating: "x", count: 512 * 1024)
  try Data(
    ("{\"payload\":\"\(oversizedPayload)\"}\n"
      + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n").utf8
  ).write(to: oversizedFile)
  var filteredObjects = 0
  let oversizedSummary = try JSONLReader.forEachObject(
    at: oversizedFile,
    lineMustContainOneOf: ["token_count"]
  ) { _, _ in
    filteredObjects += 1
  }
  check(
    filteredObjects == 1 && oversizedSummary.invalidLines == 0,
    "Oversized JSONL lines are streamed and filtered")

  let knownReport = PricingEngine().calculate(
    AnalysisResult(root: codex.metadata, sessions: [codex]))
  check(knownReport.accuracy == .exact, "Known model price accuracy")
  check(
    knownReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "0.00115",
    "Codex cost calculation")
  check(knownReport.toolCostsIncluded == false, "Tool cost boundary")

  let tierSession = try CodexLogAdapter().parse(at: fixture("codex-tier"), defaultServiceTier: nil)
  check(
    tierSession.records.map(\.serviceTier) == [.standard, .fast],
    "Codex tier changes chronologically")
  check(
    tierSession.records.map(\.requestID) == ["standard-turn", "fast-turn"],
    "Codex request provenance follows turns")
  let tierReport = PricingEngine().calculate(
    AnalysisResult(root: tierSession.metadata, sessions: [tierSession]))
  check(tierReport.accuracy == .exact, "Known Standard/Fast tiers price exactly")
  check(
    tierReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "1.2",
    "Fast tier applies 2x multiplier only to matching record")
  check(
    tierReport.lines.map(\.tierMultiplier) == [1, 2], "Tier multiplier is auditable per cost line")

  let tierEdgeSession = try CodexLogAdapter().parse(
    at: fixture("codex-tier-edge"), defaultServiceTier: .fast)
  check(
    tierEdgeSession.records.map(\.serviceTier) == [.fast, .standard, .standard, .unknown],
    "Codex absent tier preserves state and unknown tier clears it")
  check(
    tierEdgeSession.records.map(\.serviceTierClassificationSource) == [
      .configuration, .log, .log, .log,
    ], "Codex tier classification source is preserved")

  let unknownTierRecord = UsageRecord(
    id: "unknown-tier", provider: .codex, sessionID: "unknown-tier", requestID: "unknown-tier",
    modelID: "gpt-5.6-sol", timestamp: Date(), usage: UsageBreakdown(inputUncached: 100_000),
    serviceTier: .unknown, serviceTierClassificationSource: .log, sourceFile: "/tmp/unknown-tier")
  let unknownTierSession = ParsedSession(
    metadata: codex.metadata, records: [unknownTierRecord], parserVersion: "test")
  let unknownTierReport = PricingEngine().calculate(
    AnalysisResult(root: codex.metadata, sessions: [unknownTierSession]))
  check(
    unknownTierReport.accuracy == .partial && unknownTierReport.tokenCostUSD != nil,
    "Unknown Codex tier fails to a lower-bound partial cost")

  let unknownMetadata = SessionMetadata(
    provider: .codex, sessionID: "unknown", originator: "codex_work_desktop",
    sourceFile: "/tmp/test", isDesktop: true)
  let unknownRecord = UsageRecord(
    id: "unknown", provider: .codex, sessionID: "unknown", requestID: "unknown",
    modelID: "future-model", timestamp: Date(), usage: UsageBreakdown(inputUncached: 1_000),
    sourceFile: "/tmp/test")
  let unknownSession = ParsedSession(
    metadata: unknownMetadata, records: [unknownRecord], parserVersion: "test")
  let unknownReport = PricingEngine().calculate(
    AnalysisResult(root: unknownMetadata, sessions: [unknownSession]))
  check(
    unknownReport.accuracy == .unavailable && unknownReport.tokenCostUSD == nil,
    "Unknown model fails closed")

  let claudePricingMetadata = SessionMetadata(
    provider: .claude, sessionID: "claude-pricing", originator: "cli",
    sourceFile: "/tmp/claude-pricing", isDesktop: false)
  let fableUsage = UsageBreakdown(
    inputUncached: 100_000, inputCachedRead: 100_000, cacheWrite5m: 100_000, cacheWrite1h: 100_000,
    output: 100_000)
  let fable5Record = UsageRecord(
    id: "fable-5", provider: .claude, sessionID: "claude-pricing", requestID: "fable-5",
    modelID: "claude-fable-5", timestamp: Date(), usage: fableUsage,
    sourceFile: "/tmp/claude-pricing")
  let fable51Record = UsageRecord(
    id: "fable-5-1", provider: .claude, sessionID: "claude-pricing", requestID: "fable-5-1",
    modelID: "claude-fable-5-1", timestamp: Date(), usage: fableUsage,
    sourceFile: "/tmp/claude-pricing")
  let fable5Report = PricingEngine().calculate(
    AnalysisResult(
      root: claudePricingMetadata,
      sessions: [
        ParsedSession(
          metadata: claudePricingMetadata, records: [fable5Record], parserVersion: "test")
      ]))
  let fable51Report = PricingEngine().calculate(
    AnalysisResult(
      root: claudePricingMetadata,
      sessions: [
        ParsedSession(
          metadata: claudePricingMetadata, records: [fable51Record], parserVersion: "test")
      ]))
  check(
    fable5Report.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "9.35",
    "Claude Fable 5 price")
  check(
    fable51Report.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "9.275",
    "Claude Fable 5.1 price")
  check(
    PriceCatalog.webinar2026September02.price(
      for: "claude-fable-5-1", provider: .claude, at: Date.distantFuture)?.cachedReadPerMillion
      == Decimal(string: "0.25")
      && PriceCatalog.webinar2026September02.price(
        for: "sonnet", provider: .claude, at: Date.distantFuture)?.modelID == "claude-sonnet-5"
      && PriceCatalog.webinar2026September02.price(
        for: "claude-haiku-4-5-20251001", provider: .claude, at: Date.distantFuture)?.modelID
        == "claude-haiku-4-5",
    "Claude pricing selects specific model and aliases"
  )

  let longMetadata = SessionMetadata(
    provider: .claude, sessionID: "long", originator: "claude-desktop", sourceFile: "/tmp/long",
    isDesktop: true)
  let longRecord = UsageRecord(
    id: "long", provider: .claude, sessionID: "long", requestID: "long", modelID: "claude-opus-5",
    timestamp: Date(), usage: UsageBreakdown(inputUncached: 300_000, output: 1_000),
    sourceFile: "/tmp/long")
  let longSession = ParsedSession(
    metadata: longMetadata, records: [longRecord], parserVersion: "test")
  let longReport = PricingEngine().calculate(
    AnalysisResult(root: longMetadata, sessions: [longSession]))
  check(
    longReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "1.525",
    "Claude 1M context keeps standard pricing")

  let activityBase = Date(timeIntervalSince1970: 1_000)
  let activityRecords = [
    UsageRecord(
      id: "activity-1", provider: .claude, sessionID: "activity", requestID: "1",
      modelID: "claude-opus-5", timestamp: activityBase, usage: UsageBreakdown(inputUncached: 10),
      sourceFile: "/tmp/activity"),
    UsageRecord(
      id: "activity-2", provider: .claude, sessionID: "activity", requestID: "2",
      modelID: "claude-opus-5", timestamp: activityBase.addingTimeInterval(10 * 60),
      usage: UsageBreakdown(inputUncached: 20), sourceFile: "/tmp/activity"),
    UsageRecord(
      id: "activity-3", provider: .claude, sessionID: "activity", requestID: "3",
      modelID: "claude-opus-5", timestamp: activityBase.addingTimeInterval(45 * 60),
      usage: UsageBreakdown(inputUncached: 30), sourceFile: "/tmp/activity"),
  ]
  let activitySession = ParsedSession(
    metadata: longMetadata, records: activityRecords, parserVersion: "test")
  let activityAnalysis = AnalysisResult(root: longMetadata, sessions: [activitySession])
  let resumedAt = activityAnalysis.latestActivityStart(afterInactivity: 30 * 60)
  check(resumedAt == activityRecords[2].timestamp, "Activity resumes after 30 minute gap")
  check(
    activityAnalysis.filteringRecords(from: resumedAt!).totalUsage.total == 30,
    "Activity slice excludes thread history")

  let configDirectory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: configDirectory) }
  let configURL = configDirectory.appendingPathComponent("config.toml")
  try Data("model = \"gpt-5.6-sol\"\nservice_tier = \"priority\"\n".utf8).write(to: configURL)
  check(
    CodexConfiguration.defaultServiceTier(at: configURL) == .fast,
    "Codex config priority maps to Fast")

  let oldRuns = RunStore(storageURL: fixtureFile("run-v0.3", extension: "json")).load()
  check(
    oldRuns.count == 1 && oldRuns[0].lastAnalysis?.totalUsage.total == 110,
    "Version 0.3 persisted run remains readable")
  check(
    oldRuns[0].lastAnalysis?.sessions.first?.records.first?.messageID == nil,
    "Missing v0.4 provenance decodes safely")

  let exportRun = BenchmarkRun(
    runID: "BUILD_CODEX_01", label: "Build", provider: .codex, endedAt: Date(),
    lastAnalysis: AnalysisResult(root: codex.metadata, sessions: [codex]),
    lastCostReport: knownReport)
  let csv = BenchmarkExporter().csv(runs: [exportRun])
  check(
    csv.contains("webinar-2026-09-02-v2") && csv.contains("BUILD_CODEX_01")
      && csv.contains("normalizer_versions"), "Auditable CSV export")
} catch {
  failures.append("Unexpected error: \(error)")
  print("FAIL  Unexpected error: \(error)")
}

if failures.isEmpty {
  print("\nAll Tokenozaur self-tests passed.")
  exit(0)
} else {
  print("\n\(failures.count) self-test(s) failed:")
  for failure in failures {
    print("- \(failure)")
  }
  exit(1)
}
