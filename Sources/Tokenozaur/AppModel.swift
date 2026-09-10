import AppKit
import Foundation
import TokenozaurCore

private let activityInactivityThreshold: TimeInterval = 30 * 60
private let foregroundMonitoringRefreshInterval: TimeInterval = 10
private let backgroundMonitoringRefreshInterval: TimeInterval = 60
private let archiveRefreshInterval: TimeInterval = 5 * 60

struct MonitoredSession: Identifiable, Sendable {
  var id: String { candidate.id }
  let candidate: SessionCandidate
  let analysis: AnalysisResult
  let costReport: CostReport
  let currentActivity: AnalysisResult
  let currentActivityCostReport: CostReport
  let currentActivityStartedAt: Date

  var provider: Provider { candidate.metadata.provider }
  var modifiedAt: Date { candidate.modifiedAt }

  var displayName: String {
    candidate.displayName
  }
}

enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
  case today
  case sevenDays
  case month
  case year

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .today: return "Dzisiaj"
    case .sevenDays: return "7 dni"
    case .month: return "Miesiąc"
    case .year: return "Rok"
    }
  }
}

struct PeriodUsageSummary: Identifiable, Sendable {
  var id: UsagePeriod { period }
  let period: UsagePeriod
  let startedAt: Date
  let usage: UsageArchiveSummary
}

struct MonthlyUsageSummary: Identifiable, Sendable {
  var id: Date { startedAt }
  let startedAt: Date
  let usage: UsageArchiveSummary

  func tokens(for provider: Provider) -> Int64 {
    usage.tokens(for: provider)
  }
}

private struct ArchiveYearViewData: Sendable {
  let year: Int
  let usage: UsageArchiveSummary
  let months: [MonthlyUsageSummary]
}

private struct ArchiveRefreshOutput: Sendable {
  let cache: [String: CachedSessionSnapshot]
  let periods: [PeriodUsageSummary]
  let warnings: [String]
  let availableYears: [Int]
  let selectedYear: ArchiveYearViewData
  let archivedRecordCount: Int
}

@MainActor
final class AppModel: ObservableObject {
  @Published var runs: [BenchmarkRun] = []
  @Published var activeRunID: UUID?
  @Published var selectedProvider: Provider = .codex
  @Published var newRunLabel = ""
  @Published var recentSessions: [SessionCandidate] = []
  @Published var statusMessage = "Gotowy"
  @Published var isRefreshing = false
  @Published var lastError: String?
  @Published var monitoredSessions: [MonitoredSession] = []
  @Published var isMonitoring = false
  @Published var lastMonitoringRefresh: Date?
  @Published var monitoringWarnings: [String] = []
  @Published private(set) var isPopoverVisible = false
  @Published var periodSummaries: [PeriodUsageSummary] = []
  @Published var monthlySummaries: [MonthlyUsageSummary] = []
  @Published var availableArchiveYears: [Int] = []
  @Published var selectedArchiveYear = Calendar.autoupdatingCurrent.component(.year, from: Date())
  @Published var archiveYearSummary: UsageArchiveSummary?
  @Published var archivedRecordCount = 0
  @Published var isRefreshingPeriods = false
  @Published var periodWarnings: [String] = []

  let discovery: SessionDiscovery
  private let analyzer: SessionAnalyzer
  private let pricingEngine: PricingEngine
  private let store: RunStore
  private let historyCacheStore: SessionHistoryCacheStore
  private let usageArchiveStore: UsageArchiveStore
  private let exporter = BenchmarkExporter()
  private var baselinePaths: Set<String> = []
  private var historyFileCache: [String: CachedSessionSnapshot] = [:]
  private var lastPeriodRefresh: Date?
  private var timer: Timer?

  init(
    discovery: SessionDiscovery = SessionDiscovery(),
    store: RunStore = RunStore(),
    usageArchiveStore: UsageArchiveStore = UsageArchiveStore()
  ) {
    self.discovery = discovery
    self.analyzer = SessionAnalyzer(discovery: discovery)
    self.pricingEngine = PricingEngine()
    self.store = store
    self.historyCacheStore = SessionHistoryCacheStore()
    self.usageArchiveStore = usageArchiveStore
    self.historyFileCache = historyCacheStore.load()
    self.runs = store.load().sorted { $0.createdAt > $1.createdAt }
    self.activeRunID = runs.first(where: { $0.endedAt == nil })?.id
    startTimer()
    refreshMonitoredSessions()
    refreshRecentSessions()
    refreshActiveRun()
  }

  deinit {
    timer?.invalidate()
  }

  var activeRun: BenchmarkRun? {
    guard let activeRunID else { return nil }
    return runs.first(where: { $0.id == activeRunID })
  }

  var menuBarTitle: String {
    if let run = activeRun, let report = run.lastCostReport, report.tokenCostUSD != nil {
      return "🦖 \(Self.costLabel(report))"
    }
    if let run = activeRun, let tokens = run.lastAnalysis?.totalUsage.total, tokens > 0 {
      return "🦖 \(Self.compactTokens(tokens))"
    }
    guard let latest = monitoredSessions.first else { return "🦖" }
    if latest.currentActivityCostReport.tokenCostUSD != nil {
      return "🦖 \(Self.costLabel(latest.currentActivityCostReport))"
    }
    return "🦖 \(Self.compactTokens(latest.currentActivity.totalUsage.total))"
  }

  func refreshMonitoredSessions(force: Bool = false) {
    guard !isMonitoring else { return }
    let refreshInterval =
      isPopoverVisible
      ? foregroundMonitoringRefreshInterval
      : backgroundMonitoringRefreshInterval
    if !force,
      let lastMonitoringRefresh,
      Date().timeIntervalSince(lastMonitoringRefresh) < refreshInterval
    {
      return
    }
    isMonitoring = true

    let discovery = self.discovery
    let analyzer = self.analyzer
    let pricing = self.pricingEngine
    let cached = Dictionary(uniqueKeysWithValues: monitoredSessions.map { ($0.id, $0) })

    Task {
      let refreshed = await Task.detached(priority: .utility) {
        () -> ([MonitoredSession], [String]) in
        let cutoff = Date().addingTimeInterval(-activityInactivityThreshold)
        let candidates = Provider.allCases
          .flatMap { discovery.recentInteractiveSessions(provider: $0, limit: 6) }
          .filter { $0.modifiedAt >= cutoff }
          .sorted { $0.modifiedAt > $1.modifiedAt }
          .prefix(6)

        var sessions: [MonitoredSession] = []
        var warnings: [String] = []
        for candidate in candidates {
          if let cachedSession = cached[candidate.id],
            cachedSession.modifiedAt == candidate.modifiedAt
          {
            sessions.append(cachedSession)
            continue
          }
          do {
            let analysis = try analyzer.analyze(
              rootURL: candidate.url,
              provider: candidate.metadata.provider
            )
            let activityStart =
              analysis.latestActivityStart(afterInactivity: activityInactivityThreshold)
              ?? analysis.root.startedAt
              ?? candidate.modifiedAt
            let currentActivity = analysis.filteringRecords(from: activityStart)
            sessions.append(
              MonitoredSession(
                candidate: candidate,
                analysis: analysis,
                costReport: pricing.calculate(analysis),
                currentActivity: currentActivity,
                currentActivityCostReport: pricing.calculate(currentActivity),
                currentActivityStartedAt: activityStart
              ))
          } catch {
            warnings.append(
              "\(candidate.metadata.provider.displayName): \(error.localizedDescription)")
          }
        }
        return (sessions.sorted { $0.modifiedAt > $1.modifiedAt }, warnings)
      }.value

      self.monitoredSessions = refreshed.0
      self.monitoringWarnings = refreshed.1
      self.lastMonitoringRefresh = Date()
      self.isMonitoring = false
    }
  }

  func setPopoverVisible(_ isVisible: Bool) {
    isPopoverVisible = isVisible
    if isVisible {
      refreshMonitoredSessions(force: true)
    }
  }

  func refreshPeriodSummaries() {
    guard !isRefreshingPeriods else { return }
    isRefreshingPeriods = true

    let discovery = self.discovery
    let pricing = self.pricingEngine
    let historyCacheStore = self.historyCacheStore
    let archiveStore = self.usageArchiveStore
    let cached = self.historyFileCache
    let requestedYear = self.selectedArchiveYear

    Task {
      let outcome = await Task.detached(priority: .utility) {
        () -> Result<ArchiveRefreshOutput, Error> in
        do {
          let allCandidates = Provider.allCases.flatMap {
            discovery.allInteractiveSessionFiles(provider: $0)
          }
          var workingCache = cached
          var changedSourceFiles: Set<String> = []
          var warnings: [String] = []

          // An active Codex rollout supersedes an archived copy with the same ID.
          let currentCodexPaths = Dictionary(
            allCandidates
              .filter { $0.metadata.provider == .codex }
              .map { ($0.metadata.sessionID, $0.id) },
            uniquingKeysWith: { first, _ in first }
          )
          workingCache = workingCache.filter { key, snapshot in
            guard snapshot.candidate.metadata.provider == .codex,
              let currentPath = currentCodexPaths[snapshot.candidate.metadata.sessionID]
            else {
              return true
            }
            return key == currentPath
          }

          for candidate in allCandidates {
            if let existing = workingCache[candidate.id],
              existing.candidate.modifiedAt == candidate.modifiedAt
            {
              continue
            }
            do {
              let parsed: ParsedSession
              switch candidate.metadata.provider {
              case .codex: parsed = try CodexLogAdapter().parse(at: candidate.url)
              case .claude: parsed = try ClaudeLogAdapter().parse(at: candidate.url)
              }
              workingCache[candidate.id] = CachedSessionSnapshot(
                candidate: candidate,
                session: parsed
              )
              changedSourceFiles.insert(parsed.metadata.sourceFile)
            } catch {
              warnings.append(
                "\(candidate.metadata.provider.displayName): \(error.localizedDescription)")
            }
          }

          let normalized = UsageNormalizer().normalize(
            workingCache.values.map(\.session)
          )
          let archiveWasEmpty = try archiveStore.recordCount() == 0
          let pricingChanged = try archiveStore.needsRepricing(
            for: pricing.catalog.snapshotID
          )
          let sessionsToArchive =
            archiveWasEmpty || pricingChanged
            ? normalized
            : normalized.filter { changedSourceFiles.contains($0.metadata.sourceFile) }
          try archiveStore.sync(sessions: sessionsToArchive, pricing: pricing)
          if workingCache != cached {
            try historyCacheStore.save(workingCache)
          }

          let now = Date()
          let calendar = Calendar.autoupdatingCurrent
          let today = calendar.startOfDay(for: now)
          let starts: [(UsagePeriod, Date)] = [
            (.today, today),
            (.sevenDays, calendar.date(byAdding: .day, value: -6, to: today) ?? today),
            (.month, calendar.dateInterval(of: .month, for: now)?.start ?? today),
            (.year, calendar.dateInterval(of: .year, for: now)?.start ?? today),
          ]
          let periods = try starts.map { period, start in
            return PeriodUsageSummary(
              period: period,
              startedAt: start,
              usage: try archiveStore.summary(from: start, through: now)
            )
          }

          let currentYear = calendar.component(.year, from: now)
          var years = try archiveStore.availableYears()
          if !years.contains(currentYear) { years.insert(currentYear, at: 0) }
          let resolvedYear = years.contains(requestedYear) ? requestedYear : currentYear
          let yearView = try Self.loadArchiveYear(
            resolvedYear,
            archiveStore: archiveStore,
            calendar: calendar,
            now: now
          )
          return .success(
            ArchiveRefreshOutput(
              cache: workingCache,
              periods: periods,
              warnings: Array(Set(warnings)).sorted(),
              availableYears: years,
              selectedYear: yearView,
              archivedRecordCount: try archiveStore.recordCount()
            )
          )
        } catch {
          return .failure(error)
        }
      }.value

      switch outcome {
      case .success(let output):
        self.historyFileCache = output.cache
        self.periodSummaries = output.periods
        self.periodWarnings = output.warnings
        self.availableArchiveYears = output.availableYears
        self.selectedArchiveYear = output.selectedYear.year
        self.archiveYearSummary = output.selectedYear.usage
        self.monthlySummaries = output.selectedYear.months
        self.archivedRecordCount = output.archivedRecordCount
        self.lastPeriodRefresh = Date()
      case .failure(let error):
        self.lastError = error.localizedDescription
        self.periodWarnings = [error.localizedDescription]
      }
      self.isRefreshingPeriods = false
    }
  }

  func selectArchiveYear(_ year: Int) {
    guard availableArchiveYears.contains(year), year != selectedArchiveYear else { return }
    selectedArchiveYear = year
    isRefreshingPeriods = true
    let archiveStore = self.usageArchiveStore
    Task {
      let outcome = await Task.detached(priority: .utility) {
        () -> Result<ArchiveYearViewData, Error> in
        do {
          return .success(
            try Self.loadArchiveYear(
              year,
              archiveStore: archiveStore,
              calendar: .autoupdatingCurrent,
              now: Date()
            )
          )
        } catch {
          return .failure(error)
        }
      }.value
      switch outcome {
      case .success(let output):
        self.archiveYearSummary = output.usage
        self.monthlySummaries = output.months
      case .failure(let error):
        self.lastError = error.localizedDescription
      }
      self.isRefreshingPeriods = false
    }
  }

  func startRun() {
    let trimmed = newRunLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = trimmed.isEmpty ? "Benchmark" : trimmed
    let runID = Self.makeRunID(label: label, provider: selectedProvider)
    baselinePaths = discovery.allVisiblePaths(provider: selectedProvider)
    let run = BenchmarkRun(runID: runID, label: label, provider: selectedProvider)
    runs.insert(run, at: 0)
    activeRunID = run.id
    newRunLabel = ""
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("BENCHMARK_RUN_ID: \(runID)", forType: .string)
    statusMessage = "RUN_ID skopiowany. Otwórz nową rozmowę w \(selectedProvider.displayName)."
    persist()
    refreshRecentSessions()
  }

  func attach(_ candidate: SessionCandidate) {
    guard let index = activeIndex else { return }
    runs[index].rootSessionPath = candidate.url.path
    runs[index].rootSessionID = candidate.metadata.sessionID
    statusMessage = "Dołączono sesję \(candidate.metadata.sessionID.prefix(8))."
    persist()
    refreshActiveRun()
  }

  func attachMostRecent() {
    if let candidate = recentSessions.first { attach(candidate) }
  }

  func addCheckpoint(_ kind: CheckpointKind) {
    guard let index = activeIndex else { return }
    let usage = runs[index].lastAnalysis?.totalUsage ?? .zero
    let report = runs[index].lastCostReport
    let checkpoint = UsageCheckpoint(
      kind: kind,
      usage: usage,
      apiEquivalentUSD: report?.tokenCostUSD,
      accuracy: report?.accuracy ?? .unavailable
    )
    runs[index].checkpoints.removeAll { $0.kind == kind }
    runs[index].checkpoints.append(checkpoint)
    statusMessage = "Zapisano checkpoint: \(kind.displayName)."
    persist()
  }

  func finishRun() {
    guard let index = activeIndex else { return }
    addCheckpoint(.stopped)
    runs[index].endedAt = Date()
    activeRunID = nil
    statusMessage = "Pomiar zakończony."
    persist()
    refreshRecentSessions()
  }

  func refreshActiveRun() {
    guard !isRefreshing, let run = activeRun else { return }
    isRefreshing = true
    lastError = nil
    let analyzer = self.analyzer
    let pricing = self.pricingEngine
    let discovery = self.discovery
    let excluded = baselinePaths

    Task {
      let outcome = await Task.detached(priority: .utility) {
        () -> Result<(SessionCandidate?, AnalysisResult?, CostReport?), Error> in
        do {
          var candidate: SessionCandidate?
          var rootPath = run.rootSessionPath
          if rootPath == nil {
            candidate = discovery.detectNewInteractiveSession(
              provider: run.provider,
              after: run.createdAt,
              excluding: excluded,
              containing: run.runID
            )
            rootPath = candidate?.url.path
          }
          guard let rootPath else { return .success((candidate, nil, nil)) }
          let analysis = try analyzer.analyze(
            rootURL: URL(fileURLWithPath: rootPath), provider: run.provider)
          let report = pricing.calculate(analysis)
          return .success((candidate, analysis, report))
        } catch {
          return .failure(error)
        }
      }.value

      self.isRefreshing = false
      switch outcome {
      case .success(let value):
        guard let index = self.runs.firstIndex(where: { $0.id == run.id }) else { return }
        let (candidate, analysis, report) = value
        if let candidate {
          self.runs[index].rootSessionPath = candidate.url.path
          self.runs[index].rootSessionID = candidate.metadata.sessionID
          self.statusMessage = "Automatycznie dołączono nową sesję."
        }
        if let analysis {
          self.runs[index].lastAnalysis = analysis
          self.runs[index].lastCostReport = report
          self.statusMessage =
            "Zaktualizowano \(Self.compactTokens(analysis.totalUsage.total)) tokenów."
        } else if candidate == nil {
          self.statusMessage = "Czekam na nową sesję \(run.provider.displayName)…"
        }
        self.persist()
      case .failure(let error):
        self.lastError = error.localizedDescription
        self.statusMessage = "Pomiar zatrzymany przez błąd formatu."
      }
    }
  }

  func refreshRecentSessions() {
    let provider = selectedProvider
    let discovery = self.discovery
    Task {
      let sessions = await Task.detached(priority: .utility) {
        discovery.recentInteractiveSessions(provider: provider, limit: 10)
      }.value
      if self.selectedProvider == provider {
        self.recentSessions = sessions
      }
    }
  }

  func openLogs(_ provider: Provider) {
    let url = provider == .codex ? discovery.codexRoot : discovery.claudeRoot
    NSWorkspace.shared.open(url)
  }

  func export(format: ExportFormat) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "tokenozaur-export.\(format.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      switch format {
      case .csv:
        try exporter.csv(runs: runs).write(to: url, atomically: true, encoding: .utf8)
      case .markdown:
        try exporter.markdown(runs: runs).write(to: url, atomically: true, encoding: .utf8)
      case .json:
        try exporter.json(runs: runs).write(to: url, options: .atomic)
      }
      statusMessage = "Wyeksportowano \(url.lastPathComponent)."
    } catch {
      lastError = error.localizedDescription
    }
  }

  func copyRunID() {
    guard let run = activeRun else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("BENCHMARK_RUN_ID: \(run.runID)", forType: .string)
    statusMessage = "RUN_ID skopiowany."
  }

  private var activeIndex: Int? {
    guard let activeRunID else { return nil }
    return runs.firstIndex(where: { $0.id == activeRunID })
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshMonitoredSessions()
        self?.refreshActiveRun()
        if let self,
          !self.isMonitoring,
          Date().timeIntervalSince(self.lastPeriodRefresh ?? .distantPast) >= archiveRefreshInterval
        {
          self.refreshPeriodSummaries()
        }
      }
    }
  }

  private func persist() {
    do {
      try store.save(runs)
    } catch {
      lastError = "Nie udało się zapisać historii: \(error.localizedDescription)"
    }
  }

  static func compactTokens(_ value: Int64) -> String {
    if value >= 1_000_000 {
      return String(format: "%.2fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
  }

  static func currency(_ value: Decimal) -> String {
    let number = NSDecimalNumber(decimal: value).doubleValue
    return String(format: "$%.2f", number)
  }

  static func costLabel(_ report: CostReport) -> String {
    costLabel(report.tokenCostUSD, accuracy: report.accuracy)
  }

  static func costLabel(_ value: Decimal?, accuracy: MeasurementAccuracy) -> String {
    guard let value else { return "Brak ceny" }
    let formatted = currency(value)
    return accuracy == .partial ? "≥\(formatted)" : formatted
  }

  private nonisolated static func loadArchiveYear(
    _ year: Int,
    archiveStore: UsageArchiveStore,
    calendar: Calendar,
    now: Date
  ) throws -> ArchiveYearViewData {
    guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
      let nextYearStart = calendar.date(byAdding: .year, value: 1, to: yearStart)
    else {
      throw UsageArchiveError.sqlite("Nie udało się wyznaczyć granic roku \(year).")
    }
    let currentYear = calendar.component(.year, from: now)
    let yearEnd = year == currentYear ? now : nextYearStart.addingTimeInterval(-0.001)
    let yearUsage = try archiveStore.summary(from: yearStart, through: yearEnd)
    let elapsedMonths = max(
      0,
      calendar.dateComponents(
        [.month],
        from: yearStart,
        to: calendar.dateInterval(of: .month, for: yearEnd)?.start ?? yearStart
      ).month ?? 0
    )
    let months: [MonthlyUsageSummary] = try (0...min(11, elapsedMonths)).compactMap {
      offset -> MonthlyUsageSummary? in
      guard let monthStart = calendar.date(byAdding: .month, value: offset, to: yearStart),
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: monthStart)
      else {
        return nil
      }
      let monthEnd = min(yearEnd, nextMonthStart.addingTimeInterval(-0.001))
      return MonthlyUsageSummary(
        startedAt: monthStart,
        usage: try archiveStore.summary(from: monthStart, through: monthEnd)
      )
    }
    return ArchiveYearViewData(
      year: year,
      usage: yearUsage,
      months: months
    )
  }

  private static func makeRunID(label: String, provider: Provider) -> String {
    let cleaned =
      label
      .folding(
        options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL")
      )
      .uppercased()
      .map { $0.isLetter || $0.isNumber ? String($0) : "_" }
      .joined()
      .replacingOccurrences(of: "__", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    let timestamp = Int(Date().timeIntervalSince1970)
    return
      "\(cleaned.isEmpty ? "BENCHMARK" : cleaned)_\(provider.rawValue.uppercased())_\(timestamp)"
  }
}

enum ExportFormat: String, CaseIterable, Identifiable {
  case csv
  case markdown
  case json

  var id: String { rawValue }
  var fileExtension: String { self == .markdown ? "md" : rawValue }
  var displayName: String { self == .markdown ? "Markdown" : rawValue.uppercased() }
}
