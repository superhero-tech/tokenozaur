import AppKit
import SwiftUI
import TokenozercaCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var benchmarkExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                periodOverview
                liveSessions
                benchmark
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

    private var periodOverview: some View {
        let maxTokens = max(1, model.periodSummaries.map { $0.analysis.totalUsage.total }.max() ?? 1)
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
                    Button { model.refreshPeriodSummaries() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Przelicz okresy")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(UsagePeriod.allCases) { period in
                    if let summary = model.periodSummaries.first(where: { $0.period == period }) {
                        periodCard(summary, maxTokens: maxTokens)
                    } else {
                        periodPlaceholder(period)
                    }
                }
            }

            Text("Usage według czasu odpowiedzi. Okresy nakładają się.")
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

    private func periodCard(_ summary: PeriodUsageSummary, maxTokens: Int64) -> some View {
        let tokens = summary.analysis.totalUsage.total
        let ratio = sqrt(Double(tokens) / Double(maxTokens))
        let color = summary.costReport.accuracy == .exact ? Color.green : Color.orange
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(summary.period.displayName)
                    .font(.caption.bold())
                Spacer()
                Text(AppModel.costLabel(summary.costReport))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(summary.costReport.accuracy == .exact ? Color.primary : Color.orange)
            }
            Text("\(AppModel.compactTokens(tokens)) tokenów")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: max(tokens > 0 ? 4 : 0, geometry.size.width * ratio))
                }
            }
            .frame(height: 4)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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

    private var liveSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aktywne sesje").font(.headline)
                    Text("Codex i Claude • automatycznie")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isMonitoring {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.refreshMonitoredSessions() } label: {
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
                    Text("Nowa lub wznowiona rozmowa pojawi się tutaj bez RUN_ID. Pokazujemy sesje aktualizowane w ostatnich 30 minutach.")
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
                    Text(session.currentActivityStartedAt, style: .relative)
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
                            .foregroundStyle(session.costReport.accuracy == .exact ? Color.secondary : Color.orange)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(session.provider == .codex ? "Cx" : "Cl")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(session.provider == .codex ? Color.green : Color.orange, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayName)
                        .font(.caption.bold())
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(session.provider.displayName)
                        Text("•")
                        Text(String(session.candidate.metadata.sessionID.prefix(8)))
                            .monospaced()
                        Text("•")
                        Text(session.modifiedAt, style: .relative)
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
                        .foregroundStyle(session.currentActivityCostReport.accuracy == .exact ? Color.secondary : Color.orange)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
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
                Text("Tokenożerca")
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
            Label("Czekam na nową rozmowę desktopową", systemImage: "dot.radiowaves.left.and.right")
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
            GridRow { Text("Input"); Text(AppModel.compactTokens(usage.inputUncached)).monospacedDigit() }
            GridRow { Text("Cache read"); Text(AppModel.compactTokens(usage.inputCachedRead)).monospacedDigit() }
            GridRow { Text("Cache write"); Text(AppModel.compactTokens(usage.cacheWrite5m + usage.cacheWrite1h)).monospacedDigit() }
            GridRow { Text("Output"); Text(AppModel.compactTokens(usage.output)).monospacedDigit() }
            GridRow { Text("Reasoning"); Text(AppModel.compactTokens(usage.reasoningOrThinking)).monospacedDigit() }
        }
        .font(.caption)
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
                Button { model.refreshRecentSessions() } label: { Image(systemName: "arrow.clockwise") }
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
                            Text(candidate.metadata.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Sesja")
                                .font(.caption.bold())
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
