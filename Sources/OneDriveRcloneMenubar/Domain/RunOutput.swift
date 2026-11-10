import Foundation

/// rclone's output from the latest run, arranged for the Latest run submenu and for
/// Copy Error Details. rclone starts each message with a timestamp; the lines after
/// it that have none, such as bisync's tips under an error, belong to that message.
struct RunOutput {
    /// The lines of each ERROR message, in order.
    let errorLines: [String]
    /// The lines of every other message, in order.
    let otherLines: [String]

    init(lines: [String]) {
        var errors: [String] = []
        var others: [String] = []
        var inError = false
        for line in lines {
            if line.contains(/^\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}/) || errors.isEmpty && others.isEmpty {
                inError = line.contains(/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? )?(ERROR|CRITICAL) *:/)
            }
            if inError { errors.append(line) } else { others.append(line) }
        }
        errorLines = errors
        otherLines = others
    }

    /// The submenu shows the errors first, then the end of the rest of the output.
    var errorRows: [String] { Self.rows(errorLines.suffix(15)) }
    var otherRows: [String] { Self.rows(otherLines.suffix(20)) }

    /// What a successful run changed, from the stats that rclone prints when it
    /// finishes, which the runner asks for at the NOTICE level.
    var successSummary: String {
        guard otherLines.contains(where: { $0.contains(/^\s*Elapsed time:/) }) else { return "Succeeded" }
        let copied = Self.lastCount(in: otherLines, of: /^\s*Transferred:\s+(\d+) \/ \d+,/)
        let deleted = Self.lastCount(in: otherLines, of: /^\s*Deleted:\s+(\d+) \(files\)/)
        let changes = [
            copied > 0 ? "copied \(Self.files(copied))" : nil,
            deleted > 0 ? "deleted \(Self.files(deleted))" : nil,
        ].compactMap(\.self)
        return "Succeeded: " + (changes.isEmpty ? "no files changed" : changes.joined(separator: ", "))
    }

    /// What Copy Error Details puts on the clipboard: the problem, rclone's error
    /// messages as logged (or the end of its output when it logged none), and the
    /// rclone version.
    func errorDetails(headline: String, rcloneVersion: String?) -> String {
        let lines = errorLines.isEmpty ? Array(otherLines.suffix(10)) : errorLines
        return ([headline, ""] + lines + ["", rcloneVersion ?? "rclone version unknown"]).joined(separator: "\n")
    }

    /// Menu rows: the time without the date, which the submenu's title shows, single
    /// spaces, and long lines wrapped, since a menu row cannot scroll.
    private static func rows(_ lines: ArraySlice<String>) -> [String] {
        lines.flatMap { line in
            let text = line
                .replacing(/^\d{4}\/\d{2}\/\d{2} (\d{2}:\d{2}:\d{2})/) { $0.output.1 }
                .replacing(/\s+/, with: " ")
                .trimmingCharacters(in: .whitespaces)
            return wrapped(text)
        }
    }

    private static let rowWidth = 100

    /// Breaks after the last space or slash that leaves at least a third of a row,
    /// such as between a directory and a long file name, and indents the rest.
    private static func wrapped(_ line: String) -> [String] {
        var rows: [String] = []
        var rest = Substring(line)
        while rest.count > rowWidth {
            let limit = rest.index(rest.startIndex, offsetBy: rowWidth)
            let shortest = rest.index(rest.startIndex, offsetBy: rowWidth / 3)
            let breakAt = rest[shortest..<limit].lastIndex { $0 == " " || $0 == "/" }.map { rest.index(after: $0) } ?? limit
            rows.append(String(rest[..<breakAt]).trimmingCharacters(in: .whitespaces))
            rest = Substring("    " + rest[breakAt...].drop { $0 == " " })
        }
        return rows + [String(rest)]
    }

    private static func lastCount(in lines: [String], of pattern: Regex<(Substring, Substring)>) -> Int {
        lines.reversed().lazy.compactMap { $0.firstMatch(of: pattern).flatMap { Int($0.output.1) } }.first ?? 0
    }

    private static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
}
