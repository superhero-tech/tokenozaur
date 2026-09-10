import AppKit
import SwiftUI
import TokenozaurCore

private enum DashboardSection: String, CaseIterable, Identifiable {
  case now
  case months

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .now: return "Teraz"
    case .months: return "Miesiące"
    }
  }
}

struct MenuContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var benchmarkExpanded = false
  @State private var selectedSection: DashboardSection = .now

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        sectionPicker
        if selectedSection == .now {
          periodOverview
          liveSessions
          benchmark
        } else {
          monthlyOverview
        }
        footer
      }
      .padding(16)
    }
    .frame(minHeight: 420, maxHeight: 720)
    .onChange(of: model.selectedProvider) { _ in
      model.refreshRecentSessions()
    }
    .onChange(of: model.activeRunID) { value in
      if value != nil { benchmarkExpanded = true }
    }
    .onAppear {
      benchmarkExpanded = model.activeRun != nil
    }
  }

  private var sectionPicker: some View {
    Picker("Widok", selection: $selectedSection) {
      ForEach(DashboardSection.allCases) { section in
        Text(section.displayName).tag(section)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  private var periodOverview: some View {
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Zużycie").font(.headline)
          Text("Codex + Claude")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.isRefreshingPeriods {
          ProgressView().controlSize(.small)
        } else {
          Button {
            model.refreshPeriodSummaries()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .help("Przelicz okresy")
        }
      }

      HStack(spacing: 12) {
        periodLegend("Codex", color: .blue)
        periodLegend("Claude Code", color: .orange)
      }

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(UsagePeriod.allCases) { period in
          if let summary = model.periodSummaries.first(where: { $0.period == period }) {
            periodCard(summary)
          } else {
            periodPlaceholder(period)
          }
        }
      }

      Text("Każdy pasek = 100% tokenów w okresie. Okresy nakładają się.")
        .font(.caption2)
        .foregroundStyle(.secondary)
      if let warning = model.periodWarnings.first {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  private func periodLegend(_ label: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(label)
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
  }

  private func periodCard(_ summary: PeriodUsageSummary) -> some View {
    let codexTokens = providerTokens(.codex, in: summary)
    let claudeTokens = providerTokens(.claude, in: summary)
    let tokens = codexTokens + claudeTokens
    let codexRatio = tokens > 0 ? Double(codexTokens) / Double(tokens) : 0
    return VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(summary.period.displayName)
          .font(.caption.bold())
        Spacer()
        Text(AppModel.costLabel(summary.usage.tokenCostUSD, accuracy: summary.usage.accuracy))
          .font(.caption.bold().monospacedDigit())
          .foregroundStyle(.primary)
      }
      Text("\(AppModel.compactTokens(tokens)) tokenów")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      GeometryReader { geometry in
        ZStack {
          Capsule().fill(.quaternary)
          if tokens > 0 {
            HStack(spacing: 0) {
              Color.blue
                .frame(width: geometry.size.width * codexRatio)
              Color.orange
            }
            .clipShape(Capsule())
          }
        }
      }
      .frame(height: 6)
      HStack(spacing: 4) {
        Text("Cx \(AppModel.compactTokens(codexTokens))")
          .foregroundStyle(.blue)
        Spacer(minLength: 4)
        Text("CC \(AppModel.compactTokens(claudeTokens))")
          .foregroundStyle(.orange)
      }
      .font(.caption2.monospacedDigit())
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
  }

  private func providerTokens(_ provider: Provider, in summary: PeriodUsageSummary) -> Int64 {
    summary.usage.tokens(for: provider)
  }

  private func periodPlaceholder(_ period: UsagePeriod) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(period.displayName)
        .font(.caption.bold())
      HStack(spacing: 6) {
        if model.isRefreshingPeriods {
          ProgressView().controlSize(.mini)
          Text("Przeliczam…")
        } else {
          Text("Brak danych")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      Capsule()
        .fill(.quaternary)
        .frame(height: 4)
    }
    .padding(10)
    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
  }

  private var monthlyOverview: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Zużycie miesięczne").font(.headline)
          Text("Archiwum lokalne • Desktop + CLI")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker(
          "Rok",
          selection: Binding(
            get: { model.selectedArchiveYear },
            set: { model.selectArchiveYear($0) }
          )
        ) {
          ForEach(model.availableArchiveYears, id: \.self) { year in
            Text(String(year)).tag(year)
          }
        }
        .labelsHidden()
        .frame(width: 82)
        if model.isRefreshingPeriods {
          ProgressView().controlSize(.small)
        } else {
          Button {
            model.refreshPeriodSummaries()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .help("Przelicz miesiące")
        }
      }

      HStack(spacing: 12) {
        periodLegend("Codex", color: .blue)
        periodLegend("Claude Code", color: .orange)
      }

      archiveYearOverview

      if model.monthlySummaries.isEmpty {
        HStack(spacing: 8) {
          if model.isRefreshingPeriods {
            ProgressView().controlSize(.small)
            Text("Wczytuję historię roku…")
          } else {
            Text("Brak danych miesięcznych")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
      } else {
        let maximumTokens =
          model.monthlySummaries
          .map { $0.usage.totalTokens }
          .max() ?? 0
        VStack(spacing: 9) {
          ForEach(model.monthlySummaries) { summary in
            monthlyBar(summary, maximumTokens: maximumTokens)
          }
        }
      }

      Text(
        "Długość słupka porównuje sumę tokenów między miesiącami; kolory pokazują udział narzędzi."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      Text(
        "Archiwum zachowuje metadane usage po usunięciu logów źródłowych i nie przechowuje treści rozmów."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      if let warning = model.periodWarnings.first {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  @ViewBuilder
  private var archiveYearOverview: some View {
    if let summary = model.archiveYearSummary {
      let codexTokens = summary.codexTokens
      let claudeTokens = summary.claudeTokens
      let totalTokens = codexTokens + claudeTokens
      let codexRatio = totalTokens > 0 ? Double(codexTokens) / Double(totalTokens) : 0

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("Podsumowanie \(model.selectedArchiveYear)")
            .font(.caption.bold())
          Spacer()
          Text(
            totalTokens > 0
              ? AppModel.costLabel(summary.tokenCostUSD, accuracy: summary.accuracy) : "—"
          )
          .font(.caption.bold().monospacedDigit())
          .foregroundStyle(.primary)
        }
        Text("\(AppModel.compactTokens(totalTokens)) tokenów")
          .font(.title3.bold().monospacedDigit())
        GeometryReader { geometry in
          ZStack {
            Capsule().fill(.quaternary)
            if totalTokens > 0 {
              HStack(spacing: 0) {
                Color.blue.frame(width: geometry.size.width * codexRatio)
                Color.orange
              }
              .clipShape(Capsule())
            }
          }
        }
        .frame(height: 8)
        HStack {
          Text("\(summary.sessionCount) sesji")
          Text("•")
          Text("\(summary.projectCount) projektów")
          Spacer()
          Text("\(model.archivedRecordCount) rekordów w bazie")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      .padding(10)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private func monthlyBar(_ summary: MonthlyUsageSummary, maximumTokens: Int64) -> some View {
    let codexTokens = summary.tokens(for: .codex)
    let claudeTokens = summary.tokens(for: .claude)
    let totalTokens = codexTokens + claudeTokens
    let denominator = max(1, maximumTokens)
    let codexRatio = Double(codexTokens) / Double(denominator)
    let claudeRatio = Double(claudeTokens) / Double(denominator)

    return HStack(spacing: 8) {
      Text(monthLabel(summary.startedAt))
        .font(.caption.bold())
        .frame(width: 28, alignment: .leading)

      VStack(alignment: .leading, spacing: 3) {
        GeometryReader { geometry in
          ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            if totalTokens > 0 {
              HStack(spacing: 0) {
                Color.blue
                  .frame(width: geometry.size.width * codexRatio)
                Color.orange
                  .frame(width: geometry.size.width * claudeRatio)
              }
              .clipShape(Capsule())
            }
          }
        }
        .frame(height: 9)

        HStack(spacing: 8) {
          Text("Cx \(AppModel.compactTokens(codexTokens))")
            .foregroundStyle(.blue)
          Text("CC \(AppModel.compactTokens(claudeTokens))")
            .foregroundStyle(.orange)
        }
        .font(.caption2.monospacedDigit())
      }

      VStack(alignment: .trailing, spacing: 1) {
        Text("\(AppModel.compactTokens(totalTokens)) tok.")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        Text(
          totalTokens > 0
            ? AppModel.costLabel(summary.usage.tokenCostUSD, accuracy: summary.usage.accuracy) : "—"
        )
        .font(.caption.bold().monospacedDigit())
        .foregroundStyle(.primary)
      }
      .frame(width: 72, alignment: .trailing)
    }
    .padding(.vertical, 3)
  }

  private func monthLabel(_ date: Date) -> String {
    date.formatted(
      .dateTime
        .month(.abbreviated)
        .locale(Locale(identifier: "pl_PL"))
    )
    .replacingOccurrences(of: ".", with: "")
  }

  private var liveSessions: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Aktywne sesje").font(.headline)
          Text("Desktop + CLI • automatycznie")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if model.isMonitoring {
          ProgressView().controlSize(.small)
        } else {
          Button {
            model.refreshMonitoredSessions(force: true)
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .help("Odśwież teraz")
        }
      }

      if model.monitoredSessions.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Label("Brak aktywnych rozmów", systemImage: "moon.zzz")
            .font(.caption.bold())
          Text(
            "Nowa lub wznowiona rozmowa Desktop/CLI pojawi się tutaj bez RUN_ID. Pokazujemy sesje aktualizowane w ostatnich 30 minutach."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
      } else {
        ForEach(model.monitoredSessions) { session in
          liveSessionCard(session)
        }
      }

      if let warning = model.monitoringWarnings.first {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(2)
      }
    }
  }

  private func liveSessionCard(_ session: MonitoredSession) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Od ostatniego wznowienia")
            .font(.caption.bold())
          Spacer()
          Text(relativeTimeLabel(for: session.currentActivityStartedAt))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        sessionDetails(session.currentActivity, report: session.currentActivityCostReport)
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("Cały wątek").font(.caption.bold())
            Text("Od początku zapisanej rozmowy")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 1) {
            Text(AppModel.compactTokens(session.analysis.totalUsage.total))
              .font(.caption.bold().monospacedDigit())
            Text(AppModel.costLabel(session.costReport))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(
                session.costReport.accuracy == .exact ? Color.secondary : Color.orange)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      HStack(alignment: .center, spacing: 10) {
        Image(nsImage: ProviderLogo.image(for: session.provider))
          .resizable()
          .scaledToFit()
          .frame(width: 26, height: 26)
          .accessibilityLabel(session.provider.displayName)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.displayName)
            .font(.caption.bold())
            .lineLimit(1)
          HStack(spacing: 4) {
            Text(session.provider.displayName)
            Text("•")
            Text(session.candidate.metadata.sourceDisplayName)
            Text("•")
            Text(String(session.candidate.metadata.sessionID.prefix(8)))
              .monospaced()
            Text("•")
            Text(relativeTimeLabel(for: session.modifiedAt))
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("od wznowienia")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(AppModel.compactTokens(session.currentActivity.totalUsage.total))
            .font(.caption.bold().monospacedDigit())
          Text(AppModel.costLabel(session.currentActivityCostReport))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(
              session.currentActivityCostReport.accuracy == .exact ? Color.secondary : Color.orange)
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
  }

  private func relativeTimeLabel(for date: Date) -> String {
    let elapsed = max(0, Int(Date().timeIntervalSince(date)))
    switch elapsed {
    case 0..<60:
      return "teraz"
    case 60..<3_600:
      return "\(elapsed / 60) min temu"
    case 3_600..<86_400:
      return "\(elapsed / 3_600) godz. temu"
    default:
      return "\(elapsed / 86_400) dni temu"
    }
  }

  private func sessionDetails(_ analysis: AnalysisResult, report: CostReport) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        metric("Tokeny", AppModel.compactTokens(analysis.totalUsage.total))
        Spacer()
        metric("API-equivalent", AppModel.costLabel(report))
      }
      Divider()
      gridUsage(analysis.totalUsage)
      ForEach(analysis.modelUsage) { model in
        HStack {
          Text(model.modelID)
          Spacer()
          Text("\(model.requestCount) requestów")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
      }
      if let tierSummary = serviceTierSummary(analysis) {
        HStack {
          Text("Tryb")
          Spacer()
          Text(tierSummary)
        }
        .font(.caption2.monospaced())
        .foregroundStyle(tierSummary.contains("Nieznany") ? Color.orange : Color.secondary)
      }
      HStack {
        Text("Sesje: \(analysis.sessions.count)")
        Spacer()
        Text("Tool calls: \(analysis.toolCallCount)")
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      if let warning = report.warnings.first {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }
    }
  }

  private var benchmark: some View {
    DisclosureGroup(isExpanded: $benchmarkExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        Text("RUN_ID i checkpointy są potrzebne tylko do kontrolowanego porównania dwóch narzędzi.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        if let run = model.activeRun {
          activeRun(run)
        } else {
          newRun
        }
        status
        if model.activeRun?.rootSessionPath == nil {
          recentSessions
        }
        history
      }
      .padding(.top, 10)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("Benchmark kontrolowany").font(.headline)
        Text(model.activeRun == nil ? "Opcjonalny" : "Pomiar trwa")
          .font(.caption2)
          .foregroundStyle(model.activeRun == nil ? Color.secondary : Color.green)
      }
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text("Tokenozaur")
          Text("ALPHA")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.12), in: Capsule())
        }
        .font(.title2.bold())
        Text("Tokeny i API-equivalent cost")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("🦖")
        .font(.system(size: 28))
    }
  }

  private func activeRun(_ run: BenchmarkRun) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(run.label).font(.headline)
          Text(run.provider.displayName).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if model.isRefreshing { ProgressView().controlSize(.small) }
      }

      if run.rootSessionPath == nil {
        waitingForSession(run)
      } else {
        measurement(run)
      }

      HStack {
        Button("Pierwszy wynik") { model.addCheckpoint(.firstResult) }
          .disabled(run.lastAnalysis == nil)
        Button("Zaakceptowany") { model.addCheckpoint(.accepted) }
          .disabled(run.lastAnalysis == nil)
      }
      HStack {
        Button("Odśwież") { model.refreshActiveRun() }
        Button("Zakończ", role: .destructive) { model.finishRun() }
        Spacer()
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
  }

  private func waitingForSession(_ run: BenchmarkRun) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Czekam na nową rozmowę Desktop/CLI", systemImage: "dot.radiowaves.left.and.right")
      Text(run.runID)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
      HStack {
        Button("Kopiuj RUN_ID") { model.copyRunID() }
        Button("Dołącz najnowszą") { model.attachMostRecent() }
          .disabled(model.recentSessions.isEmpty)
      }
    }
  }

  private func measurement(_ run: BenchmarkRun) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let analysis = run.lastAnalysis, let report = run.lastCostReport {
        sessionDetails(analysis, report: report)
      }
      if !run.checkpoints.isEmpty {
        Divider()
        ForEach(run.checkpoints) { checkpoint in
          HStack {
            Text(checkpoint.kind.displayName)
            Spacer()
            Text(AppModel.compactTokens(checkpoint.usage.total))
            Text(AppModel.costLabel(checkpoint.apiEquivalentUSD, accuracy: checkpoint.accuracy))
              .monospacedDigit()
          }
          .font(.caption)
        }
      }
      if let report = run.lastCostReport {
        HStack {
          Text("Dokładność: \(report.accuracy.rawValue)")
          Spacer()
          Text(report.catalogSnapshotID)
        }
        .font(.caption2)
        .foregroundStyle(report.accuracy == .exact ? Color.secondary : Color.orange)
        if let firstWarning = report.warnings.first {
          Text(firstWarning)
            .font(.caption2)
            .foregroundStyle(.orange)
            .lineLimit(3)
        }
      }
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.bold()).monospacedDigit()
    }
  }

  private func gridUsage(_ usage: UsageBreakdown) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
      GridRow {
        Text("Input")
        Text(AppModel.compactTokens(usage.inputUncached)).monospacedDigit()
      }
      GridRow {
        Text("Cache read")
        Text(AppModel.compactTokens(usage.inputCachedRead)).monospacedDigit()
      }
      GridRow {
        Text("Cache write")
        Text(AppModel.compactTokens(usage.cacheWrite5m + usage.cacheWrite1h)).monospacedDigit()
      }
      GridRow {
        Text("Output")
        Text(AppModel.compactTokens(usage.output)).monospacedDigit()
      }
      GridRow {
        Text("Reasoning")
        Text(AppModel.compactTokens(usage.reasoningOrThinking)).monospacedDigit()
      }
    }
    .font(.caption)
  }

  private func serviceTierSummary(_ analysis: AnalysisResult) -> String? {
    let codexRecords = analysis.sessions
      .flatMap(\.records)
      .filter { $0.provider == .codex }
    guard !codexRecords.isEmpty else { return nil }
    let labels = Set(
      codexRecords.map { record -> String in
        switch record.serviceTier {
        case .standard: return "Standard ×1"
        case .fast: return "Fast ×2"
        case .unknown, .none: return "Nieznany"
        }
      })
    return labels.sorted().joined(separator: " + ")
  }

  private var newRun: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Nowy benchmark").font(.headline)
      TextField("Nazwa, np. Build Splitwise", text: $model.newRunLabel)
      Picker("Narzędzie", selection: $model.selectedProvider) {
        ForEach(Provider.allCases, id: \.self) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      .pickerStyle(.segmented)
      Button("Rozpocznij i skopiuj RUN_ID") { model.startRun() }
        .buttonStyle(.borderedProminent)
    }
    .padding(12)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
  }

  private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
      if let error = model.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  private var recentSessions: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Ręczne dołączenie").font(.headline)
        Spacer()
        Button {
          model.refreshRecentSessions()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
      }
      if model.recentSessions.isEmpty {
        Text("Brak wykrytych sesji \(model.selectedProvider.displayName).")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.recentSessions.prefix(4)) { candidate in
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(candidate.displayName)
                .font(.caption.bold())
                .lineLimit(1)
              Text(candidate.metadata.sessionID.prefix(12))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeRun != nil {
              Button("Dołącz") { model.attach(candidate) }
                .controlSize(.small)
            }
          }
        }
      }
    }
  }

  private var history: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Historia").font(.headline)
      ForEach(model.runs.filter { $0.endedAt != nil }.prefix(3)) { run in
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(run.label).font(.caption.bold())
            Text(run.provider.displayName).font(.caption2).foregroundStyle(.secondary)
          }
          Spacer()
          Text(run.lastCostReport.map(AppModel.costLabel) ?? "—")
            .font(.caption.monospacedDigit())
        }
      }
      if model.runs.contains(where: { $0.endedAt != nil }) {
        HStack {
          Menu("Eksportuj") {
            ForEach(ExportFormat.allCases) { format in
              Button(format.displayName) { model.export(format: format) }
            }
          }
          Spacer()
        }
      }
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      HStack {
        Button("Logi Codex") { model.openLogs(.codex) }
        Button("Logi Claude") { model.openLogs(.claude) }
        Spacer()
        Button("Zakończ aplikację") { NSApplication.shared.terminate(nil) }
      }
      .font(.caption)
      Text("API-equivalent nie jest rzeczywistym obciążeniem abonamentu.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
