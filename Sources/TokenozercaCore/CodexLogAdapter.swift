import Foundation

public struct CodexLogAdapter: Sendable {
    public static let parserVersion = "codex-jsonl-v1"

    public init() {}

    public func metadata(at url: URL) throws -> SessionMetadata {
        guard let object = try JSONLReader.firstObject(at: url),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let found = Self.metadata(from: payload, sourceFile: url.path) else {
            throw TokenozercaError.missingSessionMetadata(url.path)
        }
        return found
    }

    public func parse(at url: URL) throws -> ParsedSession {
        var sessionMetadata: SessionMetadata?
        var currentModel = "unknown"
        var previousTotal = CodexRawUsage.zero
        var records: [UsageRecord] = []
        var warnings: [String] = []
        var toolCalls = 0
        var sequence = 0

        let summary = try JSONLReader.forEachObject(at: url) { object, lineNumber in
            let type = object["type"] as? String

            if type == "session_meta", let payload = object["payload"] as? [String: Any] {
                sessionMetadata = Self.metadata(from: payload, sourceFile: url.path)
                return
            }

            if type == "turn_context", let payload = object["payload"] as? [String: Any],
               let model = payload["model"] as? String, !model.isEmpty {
                currentModel = model
                return
            }

            guard let payload = object["payload"] as? [String: Any] else { return }
            if type == "response_item", payload["type"] as? String == "custom_tool_call" {
                toolCalls += 1
                return
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totalObject = info["total_token_usage"] as? [String: Any] else { return }

            let newTotal = CodexRawUsage(json: totalObject)
            guard newTotal != previousTotal else { return }

            let rawDelta: CodexRawUsage
            if newTotal.isAtLeast(previousTotal) {
                rawDelta = newTotal.subtracting(previousTotal)
            } else if let lastObject = info["last_token_usage"] as? [String: Any] {
                rawDelta = CodexRawUsage(json: lastObject)
                warnings.append("Licznik Codexa zresetował się przy linii \(lineNumber); użyto last_token_usage.")
            } else {
                warnings.append("Pominięto reset licznika Codexa przy linii \(lineNumber).")
                previousTotal = newTotal
                return
            }

            previousTotal = newTotal
            guard rawDelta.total > 0 else { return }
            sequence += 1
            let metadata = sessionMetadata
            let sessionID = metadata?.sessionID ?? url.deletingPathExtension().lastPathComponent
            let timestamp = DateParsing.parse(object["timestamp"]) ?? Date(timeIntervalSince1970: 0)
            let normalized = rawDelta.normalized
            records.append(
                UsageRecord(
                    id: "codex:\(sessionID):\(sequence)",
                    provider: .codex,
                    sessionID: sessionID,
                    parentSessionID: metadata?.parentSessionID,
                    agentID: metadata?.agentID,
                    requestID: "\(sessionID):\(sequence)",
                    modelID: currentModel,
                    timestamp: timestamp,
                    usage: normalized,
                    sourceFile: url.path
                )
            )
        }

        guard let metadata = sessionMetadata else {
            throw TokenozercaError.missingSessionMetadata(url.path)
        }
        guard summary.validObjects > 0 else {
            throw TokenozercaError.unsupportedFormat("Pusty plik Codex: \(url.lastPathComponent)")
        }
        if summary.invalidLines > 0 {
            warnings.append("Pominięto \(summary.invalidLines) niepełnych lub uszkodzonych linii JSONL.")
        }
        if records.isEmpty {
            warnings.append("Sesja nie zawiera jeszcze rekordów token_count.")
        }
        if records.contains(where: { $0.modelID == "unknown" }) {
            warnings.append("Co najmniej jednego wywołania Codexa nie udało się przypisać do modelu.")
        }

        return ParsedSession(
            metadata: metadata,
            records: records,
            toolCallCount: toolCalls,
            warnings: warnings,
            parserVersion: Self.parserVersion
        )
    }

    private static func metadata(from payload: [String: Any], sourceFile: String) -> SessionMetadata? {
        guard let sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) else {
            return nil
        }
        let originator = (payload["originator"] as? String) ?? "unknown"
        let normalizedOriginator = originator.lowercased().replacingOccurrences(of: "_", with: " ")
        let isDesktop = normalizedOriginator.contains("desktop") || normalizedOriginator.contains("work desktop")
        let source = payload["source"] as? [String: Any]
        let subagent = source?["subagent"] as? [String: Any]
        let threadSpawn = subagent?["thread_spawn"] as? [String: Any]
        let parentID = threadSpawn?["parent_thread_id"] as? String
        let agentID = (threadSpawn?["agent_path"] as? String) ?? (threadSpawn?["agent_nickname"] as? String)

        return SessionMetadata(
            provider: .codex,
            sessionID: sessionID,
            parentSessionID: parentID,
            agentID: agentID,
            originator: originator,
            appVersion: payload["cli_version"] as? String,
            startedAt: DateParsing.parse(payload["timestamp"]),
            workingDirectory: payload["cwd"] as? String,
            sourceFile: sourceFile,
            isDesktop: isDesktop
        )
    }
}

private struct CodexRawUsage: Equatable {
    let input: Int64
    let cachedInput: Int64
    let cacheWriteInput: Int64
    let output: Int64
    let reasoningOutput: Int64

    static let zero = CodexRawUsage(input: 0, cachedInput: 0, cacheWriteInput: 0, output: 0, reasoningOutput: 0)

    init(input: Int64, cachedInput: Int64, cacheWriteInput: Int64, output: Int64, reasoningOutput: Int64) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
    }

    init(json: [String: Any]) {
        input = .fromJSON(json["input_tokens"])
        cachedInput = .fromJSON(json["cached_input_tokens"])
        cacheWriteInput = .fromJSON(json["cache_write_input_tokens"])
        output = .fromJSON(json["output_tokens"])
        reasoningOutput = .fromJSON(json["reasoning_output_tokens"])
    }

    var total: Int64 { input + output }

    func isAtLeast(_ other: CodexRawUsage) -> Bool {
        input >= other.input &&
        cachedInput >= other.cachedInput &&
        cacheWriteInput >= other.cacheWriteInput &&
        output >= other.output &&
        reasoningOutput >= other.reasoningOutput
    }

    func subtracting(_ other: CodexRawUsage) -> CodexRawUsage {
        CodexRawUsage(
            input: input - other.input,
            cachedInput: cachedInput - other.cachedInput,
            cacheWriteInput: cacheWriteInput - other.cacheWriteInput,
            output: output - other.output,
            reasoningOutput: reasoningOutput - other.reasoningOutput
        )
    }

    var normalized: UsageBreakdown {
        UsageBreakdown(
            inputUncached: max(0, input - cachedInput - cacheWriteInput),
            inputCachedRead: cachedInput,
            cacheWrite5m: cacheWriteInput,
            output: output,
            reasoningOrThinking: min(reasoningOutput, output)
        )
    }
}
