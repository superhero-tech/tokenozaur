import Foundation

public struct LongContextRule: Codable, Equatable, Sendable {
    public let thresholdInputTokens: Int64
    public let inputMultiplier: Decimal
    public let outputMultiplier: Decimal

    public init(thresholdInputTokens: Int64, inputMultiplier: Decimal, outputMultiplier: Decimal) {
        self.thresholdInputTokens = thresholdInputTokens
        self.inputMultiplier = inputMultiplier
        self.outputMultiplier = outputMultiplier
    }
}

public struct ModelPrice: Codable, Equatable, Identifiable, Sendable {
    public var id: String { modelID }
    public let provider: Provider
    public let modelID: String
    public let aliases: [String]
    public let effectiveFrom: Date
    public let inputPerMillion: Decimal
    public let cachedReadPerMillion: Decimal
    public let cacheWrite5mPerMillion: Decimal
    public let cacheWrite1hPerMillion: Decimal
    public let outputPerMillion: Decimal
    public let longContextRule: LongContextRule?
    public let sourceURL: String
    public let note: String?

    public init(
        provider: Provider,
        modelID: String,
        aliases: [String] = [],
        effectiveFrom: Date,
        inputPerMillion: Decimal,
        cachedReadPerMillion: Decimal,
        cacheWrite5mPerMillion: Decimal,
        cacheWrite1hPerMillion: Decimal,
        outputPerMillion: Decimal,
        longContextRule: LongContextRule? = nil,
        sourceURL: String,
        note: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.aliases = aliases
        self.effectiveFrom = effectiveFrom
        self.inputPerMillion = inputPerMillion
        self.cachedReadPerMillion = cachedReadPerMillion
        self.cacheWrite5mPerMillion = cacheWrite5mPerMillion
        self.cacheWrite1hPerMillion = cacheWrite1hPerMillion
        self.outputPerMillion = outputPerMillion
        self.longContextRule = longContextRule
        self.sourceURL = sourceURL
        self.note = note
    }
}

public struct PriceCatalog: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let frozenAt: Date
    public let prices: [ModelPrice]

    public init(snapshotID: String, frozenAt: Date, prices: [ModelPrice]) {
        self.snapshotID = snapshotID
        self.frozenAt = frozenAt
        self.prices = prices
    }

    public func price(for rawModelID: String, provider: Provider, at date: Date) -> ModelPrice? {
        let normalized = rawModelID.lowercased()
        return prices
            .filter { price in
                guard price.provider == provider, price.effectiveFrom <= date else { return false }
                let identifiers = [price.modelID] + price.aliases
                return identifiers.contains { identifier in
                    let candidate = identifier.lowercased()
                    return normalized == candidate || normalized.hasPrefix(candidate + "-")
                }
            }
            .sorted { $0.effectiveFrom > $1.effectiveFrom }
            .first
    }

    public static let webinar2026_09_02: PriceCatalog = {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-09-02T00:00:00Z") ?? Date(timeIntervalSince1970: 0)
        return PriceCatalog(
            snapshotID: "webinar-2026-09-02-v1",
            frozenAt: date,
            prices: [
                ModelPrice(
                    provider: .codex,
                    modelID: "gpt-5.6-sol",
                    aliases: ["gpt-5.6-sol-chatgpt"],
                    effectiveFrom: date,
                    inputPerMillion: 4,
                    cachedReadPerMillion: Decimal(string: "0.4")!,
                    cacheWrite5mPerMillion: 5,
                    cacheWrite1hPerMillion: 5,
                    outputPerMillion: 20,
                    longContextRule: LongContextRule(
                        thresholdInputTokens: 272_000,
                        inputMultiplier: 2,
                        outputMultiplier: Decimal(string: "1.5")!
                    ),
                    sourceURL: "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
                    note: "API-equivalent pricing; cache write uses the documented 1.25× input rate."
                ),
                ModelPrice(
                    provider: .claude,
                    modelID: "claude-opus-5",
                    aliases: ["opus-5"],
                    effectiveFrom: date,
                    inputPerMillion: 5,
                    cachedReadPerMillion: Decimal(string: "0.5")!,
                    cacheWrite5mPerMillion: Decimal(string: "6.25")!,
                    cacheWrite1hPerMillion: 10,
                    outputPerMillion: 25,
                    longContextRule: LongContextRule(
                        thresholdInputTokens: 200_000,
                        inputMultiplier: 2,
                        outputMultiplier: Decimal(string: "1.5")!
                    ),
                    sourceURL: "https://platform.claude.com/docs/en/about-claude/pricing",
                    note: "API-equivalent pricing with the documented premium for requests above 200K input tokens."
                )
            ]
        )
    }()
}

public struct CostComponent: Codable, Equatable, Sendable {
    public let label: String
    public let tokens: Int64
    public let ratePerMillion: Decimal
    public let multiplier: Decimal
    public let amountUSD: Decimal
}

public struct CostLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String { recordID }
    public let recordID: String
    public let provider: Provider
    public let modelID: String
    public let requestID: String
    public let components: [CostComponent]
    public let amountUSD: Decimal?
    public let accuracy: MeasurementAccuracy
    public let warning: String?
}

public struct CostReport: Codable, Equatable, Sendable {
    public let catalogSnapshotID: String
    public let calculatedAt: Date
    public let lines: [CostLine]
    public let tokenCostUSD: Decimal?
    public let accuracy: MeasurementAccuracy
    public let toolCostsIncluded: Bool
    public let warnings: [String]

    public init(
        catalogSnapshotID: String,
        calculatedAt: Date = Date(),
        lines: [CostLine],
        toolCostsIncluded: Bool,
        warnings: [String]
    ) {
        self.catalogSnapshotID = catalogSnapshotID
        self.calculatedAt = calculatedAt
        self.lines = lines
        let knownAmounts = lines.compactMap(\.amountUSD)
        self.tokenCostUSD = knownAmounts.isEmpty ? nil : knownAmounts.reduce(Decimal.zero, +)
        if lines.isEmpty || knownAmounts.isEmpty {
            self.accuracy = .unavailable
        } else if knownAmounts.count == lines.count {
            self.accuracy = .exact
        } else {
            self.accuracy = .partial
        }
        self.toolCostsIncluded = toolCostsIncluded
        self.warnings = warnings
    }
}

public struct PricingEngine: Sendable {
    public let catalog: PriceCatalog

    public init(catalog: PriceCatalog = .webinar2026_09_02) {
        self.catalog = catalog
    }

    public func calculate(_ analysis: AnalysisResult) -> CostReport {
        let records = analysis.sessions.flatMap(\.records)
        var warnings = analysis.warnings
        let lines = records.map { record -> CostLine in
            guard let price = catalog.price(for: record.modelID, provider: record.provider, at: catalog.frozenAt) else {
                return CostLine(
                    recordID: record.id,
                    provider: record.provider,
                    modelID: record.modelID,
                    requestID: record.requestID,
                    components: [],
                    amountUSD: nil,
                    accuracy: .unavailable,
                    warning: "Brak zamrożonej ceny dla modelu \(record.modelID)."
                )
            }

            let longContext = price.longContextRule.flatMap { rule in
                record.usage.totalInput > rule.thresholdInputTokens ? rule : nil
            }
            let inputMultiplier = longContext?.inputMultiplier ?? 1
            let outputMultiplier = longContext?.outputMultiplier ?? 1
            let components = [
                component("Input", tokens: record.usage.inputUncached, rate: price.inputPerMillion, multiplier: inputMultiplier),
                component("Cached input", tokens: record.usage.inputCachedRead, rate: price.cachedReadPerMillion, multiplier: inputMultiplier),
                component("Cache write 5m", tokens: record.usage.cacheWrite5m, rate: price.cacheWrite5mPerMillion, multiplier: inputMultiplier),
                component("Cache write 1h", tokens: record.usage.cacheWrite1h, rate: price.cacheWrite1hPerMillion, multiplier: inputMultiplier),
                component("Output", tokens: record.usage.output, rate: price.outputPerMillion, multiplier: outputMultiplier)
            ].filter { $0.tokens > 0 }
            let amount = components.reduce(Decimal.zero) { $0 + $1.amountUSD }
            return CostLine(
                recordID: record.id,
                provider: record.provider,
                modelID: record.modelID,
                requestID: record.requestID,
                components: components,
                amountUSD: amount,
                accuracy: .exact,
                warning: longContext == nil ? nil : "Zastosowano premium za długi kontekst."
            )
        }

        if analysis.toolCallCount > 0 {
            warnings.append("Wykryto \(analysis.toolCallCount) tool calls; raport obejmuje koszt tokenów, nie nieujawnione opłaty narzędziowe.")
        }
        let unknownModels = Set(lines.filter { $0.amountUSD == nil }.map(\.modelID)).sorted()
        if !unknownModels.isEmpty {
            warnings.append("Nie wyceniono modeli: \(unknownModels.joined(separator: ", ")).")
        }

        return CostReport(
            catalogSnapshotID: catalog.snapshotID,
            lines: lines,
            toolCostsIncluded: analysis.toolCallCount == 0,
            warnings: warnings
        )
    }

    private func component(_ label: String, tokens: Int64, rate: Decimal, multiplier: Decimal) -> CostComponent {
        let amount = Decimal(tokens) / 1_000_000 * rate * multiplier
        return CostComponent(
            label: label,
            tokens: tokens,
            ratePerMillion: rate,
            multiplier: multiplier,
            amountUSD: amount
        )
    }
}
