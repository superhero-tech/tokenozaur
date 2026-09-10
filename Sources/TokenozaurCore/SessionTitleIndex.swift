import Foundation

public struct SessionTitleIndex: Sendable {
  public let codexIndexURL: URL
  public let claudeHistoryURL: URL

  public init(
    codexIndexURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/session_index.jsonl"),
    claudeHistoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/history.jsonl")
  ) {
    self.codexIndexURL = codexIndexURL
    self.claudeHistoryURL = claudeHistoryURL
  }

  public func titles(for provider: Provider) -> [String: String] {
    switch provider {
    case .codex:
      return codexTitles()
    case .claude:
      return claudeTitles()
    }
  }

  private func codexTitles() -> [String: String] {
    var result: [String: String] = [:]
    _ = try? JSONLReader.forEachObject(at: codexIndexURL) { object, _ in
      guard let sessionID = object["id"] as? String,
        let rawTitle = object["thread_name"] as? String,
        let title = Self.cleaned(rawTitle)
      else { return }
      result[sessionID] = title
    }
    return result
  }

  private func claudeTitles() -> [String: String] {
    var earliest: [String: (timestamp: Int64, title: String)] = [:]
    _ = try? JSONLReader.forEachObject(at: claudeHistoryURL) { object, _ in
      guard let sessionID = object["sessionId"] as? String,
        let rawTitle = object["display"] as? String,
        let title = Self.cleaned(rawTitle)
      else { return }
      let timestamp = Int64.fromJSON(object["timestamp"])
      if let existing = earliest[sessionID], existing.timestamp <= timestamp {
        return
      }
      earliest[sessionID] = (timestamp, title)
    }
    return earliest.mapValues(\.title)
  }

  private static func cleaned(_ raw: String) -> String? {
    let collapsed =
      raw
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    let limit = 80
    guard collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
