import AppKit
import Foundation
import TokenozercaCore

struct MonitoredSession: Identifiable, Sendable {
    var id: String { candidate.id }
    let candidate: SessionCandidate
    let analysis: AnalysisResult
    let costReport: CostReport

    var provider: Provider { candidate.metadata.provider }
    var modifiedAt: Date { candidate.modifiedAt }

    var displayName: String {
        if let workingDirectory = candidate.metadata.workingDirectory {
            let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "Rozmowa \(candidate.metadata.sessionID.prefix(8))"
    }
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

    let discovery: SessionDiscovery
    private let analyzer: SessionAnalyzer
    private let pricingEngine: PricingEngine
    private let store: RunStore
    private let exporter = BenchmarkExporter()
    private var baselinePaths: Set<String> = []
    private var timer: Timer?

    init(
        discovery: SessionDiscovery = SessionDiscovery(),
        store: RunStore = RunStore()
    ) {
        self.discovery = discovery
        self.analyzer = SessionAnalyzer(discovery: discovery)
        self.pricingEngine = PricingEngine()
        self.store = store
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
        if latest.costReport.tokenCostUSD != nil {
            return "🦖 \(Self.costLabel(latest.costReport))"
        }
        return "🦖 \(Self.compactTokens(latest.analysis.totalUsage.total))"
    }

    func refreshMonitoredSessions() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let discovery = self.discovery
        let analyzer = self.analyzer
        let pricing = self.pricingEngine
        let cached = Dictionary(uniqueKeysWithValues: monitoredSessions.map { ($0.id, $0) })

        Task {
            let refreshed = await Task.detached(priority: .utility) { () -> ([MonitoredSession], [String]) in
                let cutoff = Date().addingTimeInterval(-30 * 60)
                let candidates = Provider.allCases
                    .flatMap { discovery.recentDesktopSessions(provider: $0, limit: 6) }
                    .filter { $0.modifiedAt >= cutoff }
                    .sorted { $0.modifiedAt > $1.modifiedAt }
                    .prefix(6)

                var sessions: [MonitoredSession] = []
                var warnings: [String] = []
                for candidate in candidates {
                    if let cachedSession = cached[candidate.id], cachedSession.modifiedAt == candidate.modifiedAt {
                        sessions.append(cachedSession)
                        continue
                    }
                    do {
                        let analysis = try analyzer.analyze(
                            rootURL: candidate.url,
                            provider: candidate.metadata.provider
                        )
                        sessions.append(MonitoredSession(
                            candidate: candidate,
                            analysis: analysis,
                            costReport: pricing.calculate(analysis)
                        ))
                    } catch {
                        warnings.append("\(candidate.metadata.provider.displayName): \(error.localizedDescription)")
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
            let outcome = await Task.detached(priority: .utility) { () -> Result<(SessionCandidate?, AnalysisResult?, CostReport?), Error> in
                do {
                    var candidate: SessionCandidate?
                    var rootPath = run.rootSessionPath
                    if rootPath == nil {
                        candidate = discovery.detectNewDesktopSession(
                            provider: run.provider,
                            after: run.createdAt,
                            excluding: excluded,
                            containing: run.runID
                        )
                        rootPath = candidate?.url.path
                    }
                    guard let rootPath else { return .success((candidate, nil, nil)) }
                    let analysis = try analyzer.analyze(rootURL: URL(fileURLWithPath: rootPath), provider: run.provider)
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
                    self.statusMessage = "Zaktualizowano \(Self.compactTokens(analysis.totalUsage.total)) tokenów."
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
                discovery.recentDesktopSessions(provider: provider, limit: 10)
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
        panel.nameFieldStringValue = "tokenozerca-export.\(format.fileExtension)"
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshMonitoredSessions()
                self?.refreshActiveRun()
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

    private static func makeRunID(label: String, provider: Provider) -> String {
        let cleaned = label
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pl_PL"))
            .uppercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "_" }
            .joined()
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let timestamp = Int(Date().timeIntervalSince1970)
        return "\(cleaned.isEmpty ? "BENCHMARK" : cleaned)_\(provider.rawValue.uppercased())_\(timestamp)"
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
