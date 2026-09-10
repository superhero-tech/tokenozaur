import Foundation

public struct JSONLReadSummary: Equatable, Sendable {
  public let validObjects: Int
  public let invalidLines: Int
}

public enum JSONLReader {
  @discardableResult
  public static func forEachObject(
    at url: URL,
    lineMustContainOneOf fragments: [String] = [],
    linePrefixObserver: ((Data.SubSequence) -> Void)? = nil,
    _ body: ([String: Any], Int) throws -> Void
  ) throws -> JSONLReadSummary {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw TokenozaurError.fileUnreadable(url.path)
    }
    defer { try? handle.close() }

    var buffer = Data()
    var validObjects = 0
    var invalidLines = 0
    var lineNumber = 0
    let maximumFilterProbeBytes = 256 * 1024
    let maximumRetainedLineBytes = 4 * 1024 * 1024
    var discardingFilteredLine = false
    // Bytes in the unfinished line that were already checked for a newline.
    // Some Codex tool-output lines are hundreds of megabytes long. Without
    // this cursor every new chunk rescans the entire unfinished line, turning
    // a linear file read into quadratic work.
    var scannedBytesInRemainder = 0
    let fragmentData = fragments.map { Data($0.utf8) }

    func shouldRead(_ line: Data.SubSequence) -> Bool {
      guard !fragmentData.isEmpty else { return true }
      let searchable = line.prefix(maximumFilterProbeBytes)
      return fragmentData.contains { searchable.range(of: $0) != nil }
    }

    while true {
      let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
      if chunk.isEmpty { break }
      if discardingFilteredLine {
        guard let newline = chunk.firstIndex(of: 0x0A) else { continue }
        lineNumber += 1
        discardingFilteredLine = false
        let remainderStart = chunk.index(after: newline)
        if remainderStart < chunk.endIndex {
          buffer.append(chunk[remainderStart...])
        }
      } else {
        buffer.append(chunk)
      }

      var consumedUpTo = buffer.startIndex
      var searchFrom = buffer.index(buffer.startIndex, offsetBy: scannedBytesInRemainder)
      while searchFrom < buffer.endIndex,
        let newline = buffer[searchFrom...].firstIndex(of: 0x0A)
      {
        let line = buffer[consumedUpTo..<newline]
        consumedUpTo = buffer.index(after: newline)
        searchFrom = consumedUpTo
        lineNumber += 1
        guard !line.isEmpty else { continue }
        linePrefixObserver?(line.prefix(maximumFilterProbeBytes))
        guard shouldRead(line) else { continue }
        autoreleasepool {
          do {
            let lineData = Data(line)
            let json = try JSONSerialization.jsonObject(with: lineData)
            guard let object = json as? [String: Any] else {
              invalidLines += 1
              return
            }
            try body(object, lineNumber)
            validObjects += 1
          } catch {
            invalidLines += 1
          }
        }
      }

      if consumedUpTo > buffer.startIndex {
        let remainingBytes = buffer.distance(from: consumedUpTo, to: buffer.endIndex)
        buffer.removeSubrange(buffer.startIndex..<consumedUpTo)
        scannedBytesInRemainder = remainingBytes
      } else {
        scannedBytesInRemainder = buffer.count
      }

      // Token logs can contain single tool-output lines hundreds of MB long.
      // Relevant row markers are emitted at the beginning of the JSON object,
      // so once a generous prefix has no marker, discard the rest of that
      // line as a stream instead of retaining and repeatedly scanning it.
      if !fragmentData.isEmpty,
        buffer.count >= maximumRetainedLineBytes
      {
        linePrefixObserver?(buffer.prefix(maximumFilterProbeBytes))
        invalidLines += 1
        buffer.removeAll(keepingCapacity: false)
        scannedBytesInRemainder = 0
        discardingFilteredLine = true
      } else if !fragmentData.isEmpty,
        buffer.count >= maximumFilterProbeBytes,
        !shouldRead(buffer[buffer.startIndex..<buffer.endIndex])
      {
        linePrefixObserver?(buffer.prefix(maximumFilterProbeBytes))
        buffer.removeAll(keepingCapacity: false)
        scannedBytesInRemainder = 0
        discardingFilteredLine = true
      }
    }

    if !buffer.isEmpty {
      lineNumber += 1
      linePrefixObserver?(buffer.prefix(maximumFilterProbeBytes))
      guard shouldRead(buffer) else {
        return JSONLReadSummary(validObjects: validObjects, invalidLines: invalidLines)
      }
      autoreleasepool {
        do {
          let json = try JSONSerialization.jsonObject(with: buffer)
          if let object = json as? [String: Any] {
            try body(object, lineNumber)
            validObjects += 1
          } else {
            invalidLines += 1
          }
        } catch {
          // A desktop app may be in the middle of appending the final JSON line.
          invalidLines += 1
        }
      }
    }

    return JSONLReadSummary(validObjects: validObjects, invalidLines: invalidLines)
  }

  public static func firstObject(at url: URL) throws -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw TokenozaurError.fileUnreadable(url.path)
    }
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 64 * 1024) ?? Data()
    guard !data.isEmpty else { return nil }
    let firstLine: Data
    if let newline = data.firstIndex(of: 0x0A) {
      firstLine = data.subdata(in: data.startIndex..<newline)
    } else {
      firstLine = data
    }
    let json = try JSONSerialization.jsonObject(with: firstLine)
    return json as? [String: Any]
  }

  public static func firstObject(
    at url: URL,
    maximumBytes: Int = 256 * 1024,
    maximumLines: Int = 64,
    matching predicate: ([String: Any]) -> Bool
  ) throws -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw TokenozaurError.fileUnreadable(url.path)
    }
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes) ?? Data()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(maximumLines) {
      guard let lineData = line.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: lineData),
        let object = json as? [String: Any]
      else { continue }
      if predicate(object) { return object }
    }
    return nil
  }

  public static func contains(_ needle: String, at url: URL, maximumBytes: Int = 2_000_000) -> Bool
  {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumBytes),
      let string = String(data: data, encoding: .utf8)
    else { return false }
    return string.contains(needle)
  }
}
