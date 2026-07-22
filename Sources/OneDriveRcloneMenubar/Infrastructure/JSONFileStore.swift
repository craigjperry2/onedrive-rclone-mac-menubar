import Foundation

struct JSONFileStore<Value: Codable>: Sendable {
    let fileURL: URL

    func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
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
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(whereSeparator: \.isNewline).suffix(limit)).map(String.init)
    }

    func trimToRecentBytes(limit: Int = maximumStoredBytes) {
        guard let data = try? Data(contentsOf: fileURL), data.count > limit else { return }
        let candidate = data.suffix(limit)
        let start = candidate.firstIndex(of: 0x0A).map { candidate.index(after: $0) } ?? candidate.startIndex
        try? Data(candidate[start...]).write(to: fileURL, options: .atomic)
    }
}
