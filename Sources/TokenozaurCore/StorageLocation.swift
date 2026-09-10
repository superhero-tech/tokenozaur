import Foundation

public enum TokenozaurStorageLocation {
  public static var directoryURL: URL {
    let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
    return resolve(in: applicationSupport)
  }

  public static func resolve(
    in applicationSupport: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let current = applicationSupport.appendingPathComponent("Tokenozaur", isDirectory: true)
    let legacy = applicationSupport.appendingPathComponent("Tokenozerca", isDirectory: true)

    if !fileManager.fileExists(atPath: current.path),
      fileManager.fileExists(atPath: legacy.path)
    {
      do {
        try fileManager.moveItem(at: legacy, to: current)
      } catch {
        // Keeping the legacy directory is safer than starting with an empty archive.
        return legacy
      }
    }

    try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
    return current
  }
}
