import Foundation

public enum CodexConfiguration {
  public static func defaultServiceTier(
    at url: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/config.toml")
  ) -> ServiceTier? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line =
        rawLine.split(separator: "#", maxSplits: 1).first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
      guard key == "service_tier" else { continue }
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        .lowercased()
      switch value {
      case "default", "standard": return .standard
      case "fast", "priority": return .fast
      default: return .unknown
      }
    }
    return nil
  }
}
