import Foundation

struct JSONFileStore<Value: Codable>: Sendable {
    let fileURL: URL

    func load() throws -> Value? {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    func save(_ value: Value) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}

struct TranscriptStore: Sendable {
    let fileURL: URL
    static let maximumStoredBytes = 64 * 1024

    func displayLines(limit: Int = 30) -> [String] {
        guard let data = recentFileData() else { return [] }
        return Self.displayLines(from: data, limit: limit)
    }

    func trimToRecentBytes(limit: Int = maximumStoredBytes) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path()),
              let size = attributes[.size] as? NSNumber,
              size.intValue > limit,
              let data = recentFileData(limit: limit) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func replace(with data: Data) throws {
        try Self.recentData(from: data).write(to: fileURL, options: .atomic)
    }

    static func displayLines(from data: Data, limit: Int = 30) -> [String] {
        guard let text = String(data: recentData(from: data), encoding: .utf8) else { return [] }
        return Array(text.split(whereSeparator: \.isNewline).suffix(limit)).map(String.init)
    }

    static func recentData(from data: Data, limit: Int = maximumStoredBytes) -> Data {
        guard data.count > limit else { return data }
        let candidate = data.suffix(limit)
        let start = candidate.firstIndex(of: 0x0A).map { candidate.index(after: $0) } ?? candidate.startIndex
        return Data(candidate[start...])
    }

    private func recentFileData(limit: Int = maximumStoredBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        return try? handle.readToEnd()
    }
}
