import Foundation

public struct JSONLReadSummary: Equatable, Sendable {
    public let validObjects: Int
    public let invalidLines: Int
}

public enum JSONLReader {
    @discardableResult
    public static func forEachObject(
        at url: URL,
        _ body: ([String: Any], Int) throws -> Void
    ) throws -> JSONLReadSummary {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw TokenozercaError.fileUnreadable(url.path)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var validObjects = 0
        var invalidLines = 0
        var lineNumber = 0

        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                lineNumber += 1
                guard !line.isEmpty else { continue }
                do {
                    let json = try JSONSerialization.jsonObject(with: Data(line))
                    guard let object = json as? [String: Any] else {
                        invalidLines += 1
                        continue
                    }
                    try body(object, lineNumber)
                    validObjects += 1
                } catch {
                    invalidLines += 1
                }
            }
        }

        if !buffer.isEmpty {
            lineNumber += 1
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

        return JSONLReadSummary(validObjects: validObjects, invalidLines: invalidLines)
    }

    public static func firstObject(at url: URL) throws -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw TokenozercaError.fileUnreadable(url.path)
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
            throw TokenozercaError.fileUnreadable(url.path)
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(maximumLines) {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData),
                  let object = json as? [String: Any] else { continue }
            if predicate(object) { return object }
        }
        return nil
    }

    public static func contains(_ needle: String, at url: URL, maximumBytes: Int = 2_000_000) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes),
              let string = String(data: data, encoding: .utf8) else { return false }
        return string.contains(needle)
    }
}
