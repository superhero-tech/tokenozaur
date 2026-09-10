import Foundation
import TokenozaurCore

let discovery = SessionDiscovery()
let analyzer = SessionAnalyzer(discovery: discovery)
let pricing = PricingEngine()

func printReport(provider: Provider, url: URL) {
  print("\n=== \(provider.displayName) ===")
  do {
    let analysis = try analyzer.analyze(rootURL: url, provider: provider)
    let report = pricing.calculate(analysis)
    print("session=\(analysis.root.sessionID)")
    print("app_version=\(analysis.root.appVersion ?? "unknown")")
    print("sessions=\(analysis.sessions.count)")
    for session in analysis.sessions {
      print("session_usage[\(session.metadata.sessionID)]=\(session.totalUsage.total)")
      print("parser[\(session.metadata.sessionID)]=\(session.parserVersion)")
      print("normalizer[\(session.metadata.sessionID)]=\(session.normalizerVersion ?? "none")")
      print(
        "dropped_replay[\(session.metadata.sessionID)]=\(session.droppedReplayRecordCount ?? 0)")
    }
    print("input_uncached=\(analysis.totalUsage.inputUncached)")
    print("cached_read=\(analysis.totalUsage.inputCachedRead)")
    print("cache_write=\(analysis.totalUsage.cacheWrite5m + analysis.totalUsage.cacheWrite1h)")
    print("output=\(analysis.totalUsage.output)")
    print("reasoning=\(analysis.totalUsage.reasoningOrThinking)")
    print("total=\(analysis.totalUsage.total)")
    print("models=\(analysis.modelUsage.map(\.modelID).joined(separator: ","))")
    print(
      "token_cost_usd=\(report.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "unavailable")"
    )
    print("accuracy=\(report.accuracy.rawValue)")
    print("warnings=\(report.warnings.count)")
    if let activityStart = analysis.latestActivityStart(afterInactivity: 30 * 60) {
      let activity = analysis.filteringRecords(from: activityStart)
      let activityReport = pricing.calculate(activity)
      print("activity_started_at=\(ISO8601DateFormatter().string(from: activityStart))")
      print("activity_total=\(activity.totalUsage.total)")
      print(
        "activity_cost_usd=\(activityReport.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "unavailable")"
      )
      print("activity_accuracy=\(activityReport.accuracy.rawValue)")
    }
  } catch {
    print("ERROR: \(error.localizedDescription)")
  }
}

func printPeriods(only requestedPeriod: String? = nil) {
  let now = Date()
  let calendar = Calendar.autoupdatingCurrent
  let today = calendar.startOfDay(for: now)
  let starts: [(String, Date)] = [
    ("today", today),
    ("seven_days", calendar.date(byAdding: .day, value: -6, to: today) ?? today),
    ("month", calendar.dateInterval(of: .month, for: now)?.start ?? today),
    ("year", calendar.dateInterval(of: .year, for: now)?.start ?? today),
  ].filter { requestedPeriod == nil || $0.0 == requestedPeriod }
  guard let earliestStart = starts.map(\.1).min() else { return }
  let allCandidates = Provider.allCases.flatMap {
    discovery.allInteractiveSessionFiles(provider: $0)
  }
  let candidates = allCandidates.filter { $0.modifiedAt >= earliestStart }
  var sessions: [ParsedSession] = []
  for candidate in candidates {
    do {
      let parsed: ParsedSession
      switch candidate.metadata.provider {
      case .codex: parsed = try CodexLogAdapter().parse(at: candidate.url)
      case .claude: parsed = try ClaudeLogAdapter().parse(at: candidate.url)
      }
      sessions.append(parsed)
    } catch {
      continue
    }
  }
  let root =
    sessions.first?.metadata
    ?? SessionMetadata(
      provider: .codex,
      sessionID: "period-summary",
      originator: "tokenozaur-probe",
      sourceFile: "local-history",
      isDesktop: true
    )
  let combined = AnalysisResult(root: root, sessions: UsageNormalizer().normalize(sessions))
  print("\n=== Periods ===")
  for (label, start) in starts {
    let analysis = combined.filteringRecords(from: start, through: now)
    let report = pricing.calculate(analysis)
    print("\(label)_parsed_files=\(candidates.count)")
    print("\(label)_tokens=\(analysis.totalUsage.total)")
    print(
      "\(label)_cost_usd=\(report.tokenCostUSD.map { NSDecimalNumber(decimal: $0).stringValue } ?? "unavailable")"
    )
    print("\(label)_accuracy=\(report.accuracy.rawValue)")
  }
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "periods" {
  printPeriods()
} else if arguments.count == 3, arguments[1] == "period" {
  printPeriods(only: arguments[2])
} else if arguments.count == 3, let provider = Provider(rawValue: arguments[1]) {
  printReport(provider: provider, url: URL(fileURLWithPath: arguments[2]))
} else {
  for provider in Provider.allCases {
    guard let candidate = discovery.recentInteractiveSessions(provider: provider, limit: 1).first
    else {
      print("\n=== \(provider.displayName) ===")
      print("No interactive Desktop/CLI session found")
      continue
    }
    printReport(provider: provider, url: candidate.url)
  }
}
