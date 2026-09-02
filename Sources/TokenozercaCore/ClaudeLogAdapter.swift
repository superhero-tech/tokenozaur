import Foundation

public struct ClaudeLogAdapter: Sendable {
    public static let parserVersion = "claude-jsonl-v1"

    public init() {}

    public func metadata(at url: URL) throws -> SessionMetadata {
        guard let object = try JSONLReader.firstObject(at: url, matching: { object in
            object["sessionId"] as? String != nil && object["entrypoint"] as? String != nil
        }),
              let found = Self.metadata(from: object, sourceFile: url.path) else {
            throw TokenozercaError.missingSessionMetadata(url.path)
        }
        return found
    }

    public func parse(at url: URL, rootSessionID: String? = nil) throws -> ParsedSession {
        var sessionMetadata: SessionMetadata?
        var recordsByMessageID: [String: UsageRecord] = [:]
        var toolCallsByMessageID: [String: Int] = [:]
        var warnings: [String] = []

        let summary = try JSONLReader.forEachObject(
            at: url,
            lineMustContainOneOf: ["\"type\":\"assistant\"", "\"entrypoint\":"]
        ) { object, lineNumber in
            if let candidate = Self.metadata(from: object, sourceFile: url.path, forcedParentID: rootSessionID),
               sessionMetadata == nil || sessionMetadata?.originator == "unknown" {
                sessionMetadata = candidate
            }

            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            let sessionID = (object["sessionId"] as? String) ?? sessionMetadata?.sessionID ?? url.deletingPathExtension().lastPathComponent
            let messageID = (message["id"] as? String) ?? (object["uuid"] as? String) ?? "line-\(lineNumber)"
            let requestID = (object["requestId"] as? String) ?? messageID
            let modelID = (message["model"] as? String) ?? "unknown"
            let cacheCreation = usage["cache_creation"] as? [String: Any]
            let cacheWrite5m = Int64.fromJSON(cacheCreation?["ephemeral_5m_input_tokens"])
            let cacheWrite1h = Int64.fromJSON(cacheCreation?["ephemeral_1h_input_tokens"])
            let aggregateCacheWrite = Int64.fromJSON(usage["cache_creation_input_tokens"])
            let classifiedWrite = cacheWrite5m + cacheWrite1h
            let unclassifiedWrite = max(0, aggregateCacheWrite - classifiedWrite)
            let outputDetails = usage["output_tokens_details"] as? [String: Any]
            let thinking = Int64.fromJSON(outputDetails?["thinking_tokens"])
            let serverTools = Self.countServerTools(usage["server_tool_use"])
            let timestamp = DateParsing.parse(object["timestamp"]) ?? Date(timeIntervalSince1970: 0)
            let metadata = sessionMetadata

            let record = UsageRecord(
                id: "claude:\(sessionID):\(messageID)",
                provider: .claude,
                sessionID: sessionID,
                parentSessionID: metadata?.parentSessionID,
                agentID: metadata?.agentID,
                requestID: requestID,
                modelID: modelID,
                timestamp: timestamp,
                usage: UsageBreakdown(
                    inputUncached: .fromJSON(usage["input_tokens"]),
                    inputCachedRead: .fromJSON(usage["cache_read_input_tokens"]),
                    cacheWrite5m: cacheWrite5m + unclassifiedWrite,
                    cacheWrite1h: cacheWrite1h,
                    output: .fromJSON(usage["output_tokens"]),
                    reasoningOrThinking: thinking
                ),
                serverToolUseCount: serverTools,
                sourceFile: url.path
            )

            if record.usage.total > 0 {
                if let existing = recordsByMessageID[messageID] {
                    // Streaming can persist the same assistant message repeatedly. Keep the
                    // newest or most complete observation, never sum both copies.
                    if record.timestamp >= existing.timestamp || record.usage.total >= existing.usage.total {
                        recordsByMessageID[messageID] = record
                    }
                } else {
                    recordsByMessageID[messageID] = record
                }
            }

            if let content = message["content"] as? [[String: Any]] {
                toolCallsByMessageID[messageID] = content.filter { $0["type"] as? String == "tool_use" }.count
            }
        }

        guard let metadata = sessionMetadata else {
            throw TokenozercaError.missingSessionMetadata(url.path)
        }
        guard summary.validObjects > 0 else {
            throw TokenozercaError.unsupportedFormat("Pusty plik Claude: \(url.lastPathComponent)")
        }
        if summary.invalidLines > 0 {
            warnings.append("Pominięto \(summary.invalidLines) niepełnych lub uszkodzonych linii JSONL.")
        }
        let records = recordsByMessageID.values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id < rhs.id }
            return lhs.timestamp < rhs.timestamp
        }
        if records.isEmpty {
            warnings.append("Sesja nie zawiera jeszcze rekordów assistant usage.")
        }
        if records.contains(where: { $0.modelID == "unknown" }) {
            warnings.append("Co najmniej jednej odpowiedzi Claude nie udało się przypisać do modelu.")
        }

        return ParsedSession(
            metadata: metadata,
            records: records,
            toolCallCount: toolCallsByMessageID.values.reduce(0, +),
            warnings: warnings,
            parserVersion: Self.parserVersion
        )
    }

    private static func metadata(
        from object: [String: Any],
        sourceFile: String,
        forcedParentID: String? = nil
    ) -> SessionMetadata? {
        guard let sessionID = object["sessionId"] as? String else { return nil }
        let entrypoint = (object["entrypoint"] as? String) ?? "unknown"
        let isSidechain = (object["isSidechain"] as? Bool) ?? false
        let agentID = object["agentId"] as? String
        let parentID = forcedParentID ?? (isSidechain ? sessionID : nil)
        return SessionMetadata(
            provider: .claude,
            sessionID: sessionID,
            parentSessionID: parentID,
            agentID: agentID,
            originator: entrypoint,
            appVersion: object["version"] as? String,
            startedAt: DateParsing.parse(object["timestamp"]),
            workingDirectory: object["cwd"] as? String,
            sourceFile: sourceFile,
            isDesktop: entrypoint == "claude-desktop"
        )
    }

    private static func countServerTools(_ value: Any?) -> Int {
        guard let dictionary = value as? [String: Any] else { return 0 }
        return dictionary.values.reduce(0) { partial, value in
            partial + Int(Int64.fromJSON(value))
        }
    }
}
