import Foundation

public final class RunStore {
  public let storageURL: URL

  public init(storageURL: URL? = nil) {
    if let storageURL {
      self.storageURL = storageURL
    } else {
      self.storageURL = TokenozaurStorageLocation.directoryURL
        .appendingPathComponent("runs.json")
    }
  }

  public func load() -> [BenchmarkRun] {
    guard let data = try? Data(contentsOf: storageURL) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([BenchmarkRun].self, from: data)) ?? []
  }

  public func save(_ runs: [BenchmarkRun]) throws {
    let directory = storageURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(runs)
    try data.write(to: storageURL, options: .atomic)
  }
}
