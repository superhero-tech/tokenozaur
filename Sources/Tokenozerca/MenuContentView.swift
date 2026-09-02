import AppKit
import SwiftUI
import TokenozercaCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let run = model.activeRun {
                    activeRun(run)
                } else {
                    newRun
                }
                status
                recentSessions
                history
                footer
            }
            .padding(16)
        }
        .frame(minHeight: 480, maxHeight: 720)
        .onChange(of: model.selectedProvider) { _ in
            model.refreshRecentSessions()
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
        let usage = run.lastAnalysis?.totalUsage ?? .zero
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                metric("Łącznie", AppModel.compactTokens(usage.total))
                Spacer()
                metric("API-equivalent", run.lastCostReport?.tokenCostUSD.map(AppModel.currency) ?? "Brak ceny")
            }
            Divider()
            gridUsage(usage)
            if let analysis = run.lastAnalysis {
                HStack {
                    Text("Sesje: \(analysis.sessions.count)")
                    Spacer()
                    Text("Tool calls: \(analysis.toolCallCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(analysis.modelUsage) { model in
                    HStack {
                        Text(model.modelID)
                        Spacer()
                        Text(AppModel.compactTokens(model.usage.total))
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
            }
            if !run.checkpoints.isEmpty {
                Divider()
                ForEach(run.checkpoints) { checkpoint in
                    HStack {
                        Text(checkpoint.kind.displayName)
                        Spacer()
                        Text(AppModel.compactTokens(checkpoint.usage.total))
                        Text(checkpoint.apiEquivalentUSD.map(AppModel.currency) ?? "—")
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
            Text("Nowy pomiar").font(.headline)
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
                Text("Ostatnie sesje").font(.headline)
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
                    Text(run.lastCostReport?.tokenCostUSD.map(AppModel.currency) ?? "—")
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
