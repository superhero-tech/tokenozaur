import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: return "Codex Desktop"
        case .claude: return "Claude Desktop"
        }
    }
}

public enum MeasurementAccuracy: String, Codable, Sendable {
    case exact
    case partial
    case unavailable
}

public struct UsageBreakdown: Codable, Equatable, Hashable, Sendable {
    public var inputUncached: Int64
    public var inputCachedRead: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var output: Int64
    public var reasoningOrThinking: Int64

    public init(
        inputUncached: Int64 = 0,
        inputCachedRead: Int64 = 0,
        cacheWrite5m: Int64 = 0,
        cacheWrite1h: Int64 = 0,
        output: Int64 = 0,
        reasoningOrThinking: Int64 = 0
    ) {
        self.inputUncached = max(0, inputUncached)
        self.inputCachedRead = max(0, inputCachedRead)
        self.cacheWrite5m = max(0, cacheWrite5m)
        self.cacheWrite1h = max(0, cacheWrite1h)
        self.output = max(0, output)
        self.reasoningOrThinking = max(0, reasoningOrThinking)
    }

    public var totalInput: Int64 {
        inputUncached + inputCachedRead + cacheWrite5m + cacheWrite1h
    }

    public var total: Int64 {
        totalInput + output
    }

    public static let zero = UsageBreakdown()

    public static func + (lhs: UsageBreakdown, rhs: UsageBreakdown) -> UsageBreakdown {
        UsageBreakdown(
            inputUncached: lhs.inputUncached + rhs.inputUncached,
            inputCachedRead: lhs.inputCachedRead + rhs.inputCachedRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            output: lhs.output + rhs.output,
            reasoningOrThinking: lhs.reasoningOrThinking + rhs.reasoningOrThinking
        )
    }

    public static func - (lhs: UsageBreakdown, rhs: UsageBreakdown) -> UsageBreakdown {
        UsageBreakdown(
            inputUncached: lhs.inputUncached - rhs.inputUncached,
            inputCachedRead: lhs.inputCachedRead - rhs.inputCachedRead,
            cacheWrite5m: lhs.cacheWrite5m - rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h - rhs.cacheWrite1h,
            output: lhs.output - rhs.output,
            reasoningOrThinking: lhs.reasoningOrThinking - rhs.reasoningOrThinking
        )
    }
}

public struct UsageRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let sessionID: String
    public let parentSessionID: String?
    public let agentID: String?
    public let requestID: String
    public let modelID: String
    public let timestamp: Date
    public let usage: UsageBreakdown
    public let serverToolUseCount: Int
    public let sourceFile: String

    public init(
        id: String,
        provider: Provider,
        sessionID: String,
        parentSessionID: String? = nil,
        agentID: String? = nil,
        requestID: String,
        modelID: String,
        timestamp: Date,
        usage: UsageBreakdown,
        serverToolUseCount: Int = 0,
        sourceFile: String
    ) {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.agentID = agentID
        self.requestID = requestID
        self.modelID = modelID
        self.timestamp = timestamp
        self.usage = usage
        self.serverToolUseCount = serverToolUseCount
        self.sourceFile = sourceFile
    }
}

public struct SessionMetadata: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { sessionID }
    public let provider: Provider
    public let sessionID: String
    public let parentSessionID: String?
    public let agentID: String?
    public let originator: String
    public let appVersion: String?
    public let startedAt: Date?
    public let workingDirectory: String?
    public let sourceFile: String
    public let isDesktop: Bool

    public init(
        provider: Provider,
        sessionID: String,
        parentSessionID: String? = nil,
        agentID: String? = nil,
        originator: String,
        appVersion: String? = nil,
        startedAt: Date? = nil,
        workingDirectory: String? = nil,
        sourceFile: String,
        isDesktop: Bool
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.agentID = agentID
        self.originator = originator
        self.appVersion = appVersion
        self.startedAt = startedAt
        self.workingDirectory = workingDirectory
        self.sourceFile = sourceFile
        self.isDesktop = isDesktop
    }
}

public struct ParsedSession: Codable, Equatable, Sendable {
    public let metadata: SessionMetadata
    public let records: [UsageRecord]
    public let toolCallCount: Int
    public let warnings: [String]
    public let parserVersion: String

    public init(
        metadata: SessionMetadata,
        records: [UsageRecord],
        toolCallCount: Int = 0,
        warnings: [String] = [],
        parserVersion: String
    ) {
        self.metadata = metadata
        self.records = records
        self.toolCallCount = toolCallCount
        self.warnings = warnings
        self.parserVersion = parserVersion
    }

    public var totalUsage: UsageBreakdown {
        records.reduce(.zero) { $0 + $1.usage }
    }
}

public struct ModelUsageSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { modelID }
    public let modelID: String
    public let usage: UsageBreakdown
    public let requestCount: Int
}

public struct AnalysisResult: Codable, Equatable, Sendable {
    public let root: SessionMetadata
    public let sessions: [ParsedSession]
    public let modelUsage: [ModelUsageSummary]
    public let totalUsage: UsageBreakdown
    public let toolCallCount: Int
    public let warnings: [String]
    public let analyzedAt: Date

    public init(root: SessionMetadata, sessions: [ParsedSession], analyzedAt: Date = Date()) {
        self.root = root
        self.sessions = sessions
        let allRecords = sessions.flatMap(\.records)
        let grouped = Dictionary(grouping: allRecords, by: \.modelID)
        self.modelUsage = grouped.map { modelID, records in
            ModelUsageSummary(
                modelID: modelID,
                usage: records.reduce(.zero) { $0 + $1.usage },
                requestCount: records.count
            )
        }.sorted { $0.modelID < $1.modelID }
        self.totalUsage = allRecords.reduce(.zero) { $0 + $1.usage }
        self.toolCallCount = sessions.reduce(0) { $0 + $1.toolCallCount }
        self.warnings = sessions.flatMap(\.warnings)
        self.analyzedAt = analyzedAt
    }
}

public enum CheckpointKind: String, Codable, CaseIterable, Sendable {
    case firstResult = "first_result"
    case accepted
    case stopped

    public var displayName: String {
        switch self {
        case .firstResult: return "Pierwszy wynik"
        case .accepted: return "Zaakceptowany"
        case .stopped: return "Zatrzymany"
        }
    }
}

public struct UsageCheckpoint: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: CheckpointKind
    public let timestamp: Date
    public let usage: UsageBreakdown
    public let apiEquivalentUSD: Decimal?
    public let accuracy: MeasurementAccuracy

    public init(
        id: UUID = UUID(),
        kind: CheckpointKind,
        timestamp: Date = Date(),
        usage: UsageBreakdown,
        apiEquivalentUSD: Decimal?,
        accuracy: MeasurementAccuracy
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.usage = usage
        self.apiEquivalentUSD = apiEquivalentUSD
        self.accuracy = accuracy
    }
}

public struct BenchmarkRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var runID: String
    public var label: String
    public var provider: Provider
    public var createdAt: Date
    public var endedAt: Date?
    public var rootSessionPath: String?
    public var rootSessionID: String?
    public var checkpoints: [UsageCheckpoint]
    public var lastAnalysis: AnalysisResult?
    public var lastCostReport: CostReport?

    public init(
        id: UUID = UUID(),
        runID: String,
        label: String,
        provider: Provider,
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        rootSessionPath: String? = nil,
        rootSessionID: String? = nil,
        checkpoints: [UsageCheckpoint] = [],
        lastAnalysis: AnalysisResult? = nil,
        lastCostReport: CostReport? = nil
    ) {
        self.id = id
        self.runID = runID
        self.label = label
        self.provider = provider
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.rootSessionPath = rootSessionPath
        self.rootSessionID = rootSessionID
        self.checkpoints = checkpoints
        self.lastAnalysis = lastAnalysis
        self.lastCostReport = lastCostReport
    }
}

public enum TokenozercaError: LocalizedError, Equatable {
    case fileUnreadable(String)
    case unsupportedFormat(String)
    case missingSessionMetadata(String)
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .fileUnreadable(let path): return "Nie można odczytać pliku: \(path)"
        case .unsupportedFormat(let detail): return "Nieobsługiwany format logu: \(detail)"
        case .missingSessionMetadata(let path): return "Brak metadanych sesji: \(path)"
        case .sessionNotFound(let detail): return "Nie znaleziono sesji: \(detail)"
        }
    }
}

public enum DateParsing {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? standard.date(from: string)
    }
}

public extension Int64 {
    static func fromJSON(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? String, let parsed = Int64(value) { return parsed }
        return 0
    }
}
