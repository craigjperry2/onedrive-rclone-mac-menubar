import Foundation

/// What went wrong in a failed rclone run, named from rclone's output. For bisync,
/// the last line is almost always the generic "Failed to bisync: bisync aborted";
/// the cause is in the ERROR and CRITICAL lines above it.
enum SyncProblem: Equatable, Sendable {
    enum Side: Equatable, Sendable {
        case oneDrive, localFolder, both

        /// The side that still has what was deleted on this one, in the menu's words.
        var otherSide: String {
            switch self {
            case .oneDrive: "your folder"
            case .localFolder: "OneDrive"
            case .both: "the other side"
            }
        }
    }

    /// bisync's listings from the last run are missing or unusable.
    case needsResync
    /// `--check-access` found RCLONE_TEST missing on one side, or on both.
    case checkFileMissing(Side)
    case signInExpired
    /// bisync's `--max-delete` safety abort: over half the files on one side were
    /// deleted since the last sync. rclone names one side; `.both` stands for a
    /// message that names neither.
    case tooManyDeletes(Side)
    case oneDriveUnreachable
    /// No known signature: rclone's first ERROR or CRITICAL line, or its last line
    /// when it reported none, without the timestamp and colour codes.
    case unrecognized(String)

    /// Names the problem in rclone's output, or nil when rclone printed nothing.
    init?(rcloneOutput output: [String]) {
        let lines = output.map(Self.withoutColourCodes)
        let errors = lines.filter { $0.contains(Self.errorLine) }
        func reports(_ phrases: String...) -> Bool {
            errors.contains { line in phrases.contains { line.localizedCaseInsensitiveContains($0) } }
        }

        if let counts = errors.lazy.compactMap({ $0.firstMatch(of: /Access test failed: Path1 count (\d+), Path2 count (\d+)/) }).first {
            // Path1 is the OneDrive remote and Path2 the local folder, as the app passes them.
            let (oneDrive, local) = (Int(counts.1) ?? 0, Int(counts.2) ?? 0)
            self = .checkFileMissing(oneDrive == 0 && local == 0 ? .both : oneDrive < local ? .oneDrive : .localFolder)
        } else if reports("must run --resync", "cannot find prior Path1 or Path2 listings") {
            self = .needsResync
        } else if reports("invalid_grant") {
            self = .signInExpired
        } else if let abort = errors.first(where: { $0.localizedCaseInsensitiveContains("Safety abort: too many deletes") }) {
            self = .tooManyDeletes(abort.contains(" on Path1 ") ? .oneDrive : abort.contains(" on Path2 ") ? .localFolder : .both)
        } else if reports("no such host", "connection refused", "network is unreachable", "no route to host", "i/o timeout") {
            self = .oneDriveUnreachable
        } else if let line = errors.first ?? lines.last(where: { !$0.allSatisfy(\.isWhitespace) }) {
            self = .unrecognized(Self.message(of: line))
        } else {
            return nil
        }
    }

    /// The plain-language name the menu and Recent Activity show.
    var name: String {
        switch self {
        case .needsResync: "rclone lost track of the last sync"
        case .checkFileMissing(.oneDrive): "The RCLONE_TEST check file is missing from OneDrive"
        case .checkFileMissing(.localFolder): "The RCLONE_TEST check file is missing from your folder"
        case .checkFileMissing(.both): "The RCLONE_TEST check file is missing from OneDrive and your folder"
        case .signInExpired: "The OneDrive sign-in has expired"
        case .tooManyDeletes(.oneDrive): "Over half the files on OneDrive were deleted since the last sync"
        case .tooManyDeletes(.localFolder): "Over half the files in your folder were deleted since the last sync"
        case .tooManyDeletes(.both): "Over half the files on one side were deleted since the last sync"
        case .oneDriveUnreachable: "OneDrive cannot be reached"
        case .unrecognized(let message): message
        }
    }

    private static var errorLine: Regex<Substring> { /^(?:\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d(?:\.\d+)? )?(?:ERROR|CRITICAL)\s*:/ }
    private static var prefix: Regex<Substring> { /^(?:\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d(?:\.\d+)? )?(?:(?:ERROR|CRITICAL|NOTICE|INFO|DEBUG)\s*:\s*)?/ }

    /// rclone colours bisync's messages even when its output is a pipe.
    private static func withoutColourCodes(_ line: String) -> String {
        line.replacing(/\x{1B}\[[0-9;]*m/, with: "")
    }

    private static func message(of line: String) -> String {
        line.replacing(prefix, with: "", maxReplacements: 1).trimmingCharacters(in: .whitespaces)
    }
}
