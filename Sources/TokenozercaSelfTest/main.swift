import Darwin
import Foundation
import TokenozercaCore

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
    guard let url = Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures") else {
        fatalError("Missing fixture: \(name)")
    }
    return url
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

do {
    let codex = try CodexLogAdapter().parse(at: fixture("codex-root"))
    check(codex.metadata.sessionID == "codex-root", "Codex metadata")
    check(codex.metadata.isDesktop, "Codex desktop originator")
    check(codex.records.count == 2, "Codex deduplicates cumulative snapshots")
    check(codex.toolCallCount == 1, "Codex tool calls")
    check(codex.totalUsage == UsageBreakdown(
        inputUncached: 140,
        inputCachedRead: 100,
        cacheWrite5m: 10,
        output: 25,
        reasoningOrThinking: 5
    ), "Codex cumulative delta math")

    let codexChild = try CodexLogAdapter().parse(at: fixture("codex-child"))
    check(codexChild.metadata.parentSessionID == "codex-root", "Codex child relation")
    check(codexChild.totalUsage.inputUncached == 40, "Codex child usage")

    let codexGuardian = try CodexLogAdapter().parse(at: fixture("codex-guardian"))
    check(codexGuardian.metadata.parentSessionID == "codex-root", "Codex direct parent relation")
    check(codexGuardian.metadata.agentID == "guardian", "Codex guardian classification")

    let claude = try ClaudeLogAdapter().parse(at: fixture("claude-root"))
    check(claude.metadata.sessionID == "claude-root", "Claude metadata")
    check(claude.metadata.isDesktop, "Claude desktop entrypoint")
    check(claude.records.count == 2, "Claude message deduplication")
    check(claude.toolCallCount == 1, "Claude deduplicated tool calls")
    check(claude.totalUsage == UsageBreakdown(
        inputUncached: 15,
        inputCachedRead: 100,
        cacheWrite5m: 20,
        cacheWrite1h: 40,
        output: 42,
        reasoningOrThinking: 5
    ), "Claude cache classification")

    let claudeChild = try ClaudeLogAdapter().parse(at: fixture("claude-child"), rootSessionID: "claude-root")
    check(claudeChild.metadata.parentSessionID == "claude-root", "Claude child relation")

    let codexTemporary = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: codexTemporary) }
    let codexRoot = codexTemporary.appendingPathComponent("codex")
    let emptyClaudeRoot = codexTemporary.appendingPathComponent("claude")
    try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptyClaudeRoot, withIntermediateDirectories: true)
    let codexRootFile = codexRoot.appendingPathComponent("root.jsonl")
    try FileManager.default.copyItem(at: fixture("codex-root"), to: codexRootFile)
    try FileManager.default.copyItem(at: fixture("codex-child"), to: codexRoot.appendingPathComponent("child.jsonl"))
    let codexAnalysis = try SessionAnalyzer(
        discovery: SessionDiscovery(codexRoot: codexRoot, claudeRoot: emptyClaudeRoot)
    ).analyze(rootURL: codexRootFile, provider: .codex)
    check(codexAnalysis.sessions.count == 2, "Codex descendant discovery")
    check(codexAnalysis.totalUsage.total == 330, "Codex graph aggregation")

    let claudeTemporary = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: claudeTemporary) }
    let emptyCodexRoot = claudeTemporary.appendingPathComponent("codex")
    let claudeRoot = claudeTemporary.appendingPathComponent("claude/project")
    try FileManager.default.createDirectory(at: emptyCodexRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    let claudeRootFile = claudeRoot.appendingPathComponent("claude-root.jsonl")
    try FileManager.default.copyItem(at: fixture("claude-root"), to: claudeRootFile)
    let subagents = claudeRoot.appendingPathComponent("claude-root/subagents")
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture("claude-child"), to: subagents.appendingPathComponent("child.jsonl"))
    let claudeAnalysis = try SessionAnalyzer(
        discovery: SessionDiscovery(codexRoot: emptyCodexRoot, claudeRoot: claudeTemporary.appendingPathComponent("claude"))
    ).analyze(rootURL: claudeRootFile, provider: .claude)
    check(claudeAnalysis.sessions.count == 2, "Claude subagent discovery")
    check(claudeAnalysis.totalUsage.output == 57, "Claude graph aggregation")

    let damagedFile = claudeTemporary.appendingPathComponent("damaged.jsonl")
    try Data("{\"valid\":true}\n{\"unfinished\":".utf8).write(to: damagedFile)
    var validDamagedObjects = 0
    let damagedSummary = try JSONLReader.forEachObject(at: damagedFile) { _, _ in
        validDamagedObjects += 1
    }
    check(validDamagedObjects == 1 && damagedSummary.invalidLines == 1, "Damaged JSONL line is reported and skipped")

    let knownReport = PricingEngine().calculate(AnalysisResult(root: codex.metadata, sessions: [codex]))
    check(knownReport.accuracy == .exact, "Known model price accuracy")
    check(knownReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "0.00115", "Codex cost calculation")
    check(knownReport.toolCostsIncluded == false, "Tool cost boundary")

    let unknownMetadata = SessionMetadata(provider: .codex, sessionID: "unknown", originator: "codex_work_desktop", sourceFile: "/tmp/test", isDesktop: true)
    let unknownRecord = UsageRecord(id: "unknown", provider: .codex, sessionID: "unknown", requestID: "unknown", modelID: "future-model", timestamp: Date(), usage: UsageBreakdown(inputUncached: 1_000), sourceFile: "/tmp/test")
    let unknownSession = ParsedSession(metadata: unknownMetadata, records: [unknownRecord], parserVersion: "test")
    let unknownReport = PricingEngine().calculate(AnalysisResult(root: unknownMetadata, sessions: [unknownSession]))
    check(unknownReport.accuracy == .unavailable && unknownReport.tokenCostUSD == nil, "Unknown model fails closed")

    let longMetadata = SessionMetadata(provider: .claude, sessionID: "long", originator: "claude-desktop", sourceFile: "/tmp/long", isDesktop: true)
    let longRecord = UsageRecord(id: "long", provider: .claude, sessionID: "long", requestID: "long", modelID: "claude-opus-5", timestamp: Date(), usage: UsageBreakdown(inputUncached: 300_000, output: 1_000), sourceFile: "/tmp/long")
    let longSession = ParsedSession(metadata: longMetadata, records: [longRecord], parserVersion: "test")
    let longReport = PricingEngine().calculate(AnalysisResult(root: longMetadata, sessions: [longSession]))
    check(longReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } == "3.0375", "Claude long-context premium")

    let activityBase = Date(timeIntervalSince1970: 1_000)
    let activityRecords = [
        UsageRecord(id: "activity-1", provider: .claude, sessionID: "activity", requestID: "1", modelID: "claude-opus-5", timestamp: activityBase, usage: UsageBreakdown(inputUncached: 10), sourceFile: "/tmp/activity"),
        UsageRecord(id: "activity-2", provider: .claude, sessionID: "activity", requestID: "2", modelID: "claude-opus-5", timestamp: activityBase.addingTimeInterval(10 * 60), usage: UsageBreakdown(inputUncached: 20), sourceFile: "/tmp/activity"),
        UsageRecord(id: "activity-3", provider: .claude, sessionID: "activity", requestID: "3", modelID: "claude-opus-5", timestamp: activityBase.addingTimeInterval(45 * 60), usage: UsageBreakdown(inputUncached: 30), sourceFile: "/tmp/activity")
    ]
    let activitySession = ParsedSession(metadata: longMetadata, records: activityRecords, parserVersion: "test")
    let activityAnalysis = AnalysisResult(root: longMetadata, sessions: [activitySession])
    let resumedAt = activityAnalysis.latestActivityStart(afterInactivity: 30 * 60)
    check(resumedAt == activityRecords[2].timestamp, "Activity resumes after 30 minute gap")
    check(activityAnalysis.filteringRecords(from: resumedAt!).totalUsage.total == 30, "Activity slice excludes thread history")

    let exportRun = BenchmarkRun(runID: "BUILD_CODEX_01", label: "Build", provider: .codex, endedAt: Date(), lastAnalysis: AnalysisResult(root: codex.metadata, sessions: [codex]), lastCostReport: knownReport)
    let csv = BenchmarkExporter().csv(runs: [exportRun])
    check(csv.contains("webinar-2026-09-02-v1") && csv.contains("BUILD_CODEX_01"), "Auditable CSV export")
} catch {
    failures.append("Unexpected error: \(error)")
    print("FAIL  Unexpected error: \(error)")
}

if failures.isEmpty {
    print("\nAll Tokenożerca self-tests passed.")
    exit(0)
} else {
    print("\n\(failures.count) self-test(s) failed:")
    failures.forEach { print("- \($0)") }
    exit(1)
}
