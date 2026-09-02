import Foundation

public struct BenchmarkExporter: Sendable {
    public init() {}

    public func csv(runs: [BenchmarkRun]) -> String {
        let header = "run_id,label,provider,started_at,ended_at,first_result_seconds,accepted_seconds,first_result_tokens,accepted_tokens,first_result_cost_usd,repair_cost_usd,accepted_cost_usd,total_tokens,input_uncached,cached_input,cache_write_5m,cache_write_1h,output,reasoning,cost_usd,accuracy,agents,tool_calls,catalog"
        let rows = runs.map(csvRow)
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func csvRow(_ run: BenchmarkRun) -> String {
        let usage = run.lastAnalysis?.totalUsage ?? .zero
        let report = run.lastCostReport
        let first = run.checkpoints.first { $0.kind == .firstResult }
        let accepted = run.checkpoints.first { $0.kind == .accepted }
        var repairCost: Decimal?
        if let acceptedCost = accepted?.apiEquivalentUSD,
           let firstCost = first?.apiEquivalentUSD {
            repairCost = acceptedCost - firstCost
        }
        var columns: [String] = []
        columns.append(escape(run.runID))
        columns.append(escape(run.label))
        columns.append(run.provider.rawValue)
        columns.append(iso(run.createdAt))
        columns.append(run.endedAt.map(iso) ?? "")
        columns.append(first.map { "\(Int($0.timestamp.timeIntervalSince(run.createdAt)))" } ?? "")
        columns.append(accepted.map { "\(Int($0.timestamp.timeIntervalSince(run.createdAt)))" } ?? "")
        columns.append(first.map { "\($0.usage.total)" } ?? "")
        columns.append(accepted.map { "\($0.usage.total)" } ?? "")
        columns.append(decimalString(first?.apiEquivalentUSD))
        columns.append(decimalString(repairCost))
        columns.append(decimalString(accepted?.apiEquivalentUSD))
        columns.append("\(usage.total)")
        columns.append("\(usage.inputUncached)")
        columns.append("\(usage.inputCachedRead)")
        columns.append("\(usage.cacheWrite5m)")
        columns.append("\(usage.cacheWrite1h)")
        columns.append("\(usage.output)")
        columns.append("\(usage.reasoningOrThinking)")
        columns.append(decimalString(report?.tokenCostUSD))
        columns.append(report?.accuracy.rawValue ?? MeasurementAccuracy.unavailable.rawValue)
        columns.append("\(run.lastAnalysis?.sessions.count ?? 0)")
        columns.append("\(run.lastAnalysis?.toolCallCount ?? 0)")
        columns.append(report?.catalogSnapshotID ?? "")
        return columns.joined(separator: ",")
    }

    public func markdown(runs: [BenchmarkRun]) -> String {
        var lines = [
            "# Tokenożerca — benchmark export",
            "",
            "| Run | Narzędzie | First result | Repair | Accepted | Tokeny | Dokładność | Agenci | Tool calls |",
            "|---|---|---:|---:|---:|---:|---|---:|---:|"
        ]
        for run in runs {
            let tokens = run.lastAnalysis?.totalUsage.total ?? 0
            let first = run.checkpoints.first { $0.kind == .firstResult }
            let accepted = run.checkpoints.first { $0.kind == .accepted }
            let firstCost = first?.apiEquivalentUSD.map { "$" + decimal($0) } ?? "—"
            let acceptedCost = accepted?.apiEquivalentUSD.map { "$" + decimal($0) } ?? "—"
            let repairCost: String = {
                guard let acceptedValue = accepted?.apiEquivalentUSD,
                      let firstValue = first?.apiEquivalentUSD else { return "—" }
                return "$" + decimal(acceptedValue - firstValue)
            }()
            lines.append("| \(run.label) | \(run.provider.displayName) | \(firstCost) | \(repairCost) | \(acceptedCost) | \(tokens) | \(run.lastCostReport?.accuracy.rawValue ?? "unavailable") | \(run.lastAnalysis?.sessions.count ?? 0) | \(run.lastAnalysis?.toolCallCount ?? 0) |")
        }
        lines.append("")
        lines.append("> API-equivalent cost nie jest rzeczywistym obciążeniem abonamentu. Tool costs są uwzględnione tylko wtedy, gdy raport mówi o tym wprost.")
        return lines.joined(separator: "\n") + "\n"
    }

    public func json(runs: [BenchmarkRun]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(runs)
    }

    private func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func decimalString(_ value: Decimal?) -> String {
        value.map(decimal) ?? ""
    }
}
