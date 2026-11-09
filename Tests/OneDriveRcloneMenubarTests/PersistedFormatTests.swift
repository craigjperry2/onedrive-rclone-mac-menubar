import Foundation
import Testing
@testable import OneDriveRcloneMenubar

/// An upgrade, such as `darwin-rebuild switch` to a new release, replaces the app
/// under the files the previous version wrote to Application Support. These
/// fixtures are what released versions write; a change that stops them decoding
/// breaks every upgraded install. Add a fixture when a format changes; never edit one.
struct PersistedFormatTests {
    @Test func releasedSettingsDecode() throws {
        let json = #"{"intervalSeconds":600,"localPath":"\/Users\/alex\/OneDrive Mirror","remoteName":"onedrive","configPath":"\/Users\/alex\/.config\/rclone\/rclone.conf","rcloneExecutablePath":""}"#

        let settings = try JSONDecoder().decode(SyncSettings.self, from: Data(json.utf8))

        #expect(settings == SyncSettings(rcloneExecutablePath: "", configPath: "/Users/alex/.config/rclone/rclone.conf", remoteName: "onedrive", localPath: "/Users/alex/OneDrive Mirror", intervalSeconds: 600))
    }

    @Test func settingsExampleInTheDocsDecodes() throws {
        let example = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/settings.example.json").standardized

        let settings = try JSONDecoder().decode(SyncSettings.self, from: Data(contentsOf: example))

        #expect(settings.rcloneExecutablePath == "")
        #expect(settings.remoteName == "onedrive")
        #expect(settings.intervalSeconds == 600)
    }

    @Test func releasedRunStatesDecode() throws {
        let failure = #"{"startedAt":800000000,"finishedAt":800000240,"outcome":"failure","failureReason":"Bisync aborted","lastSuccessAt":799999000}"#
        let firstSuccess = #"{"startedAt":800000000,"finishedAt":800000240,"outcome":"success","lastSuccessAt":800000240}"#
        let date = { Date(timeIntervalSinceReferenceDate: $0) }

        #expect(try JSONDecoder().decode(SyncRunRecord.self, from: Data(failure.utf8)) == SyncRunRecord(startedAt: date(800_000_000), finishedAt: date(800_000_240), outcome: .failure, failureReason: "Bisync aborted", lastSuccessAt: date(799_999_000)))
        #expect(try JSONDecoder().decode(SyncRunRecord.self, from: Data(firstSuccess.utf8)) == SyncRunRecord(startedAt: date(800_000_000), finishedAt: date(800_000_240), outcome: .success, failureReason: nil, lastSuccessAt: date(800_000_240)))
    }

    @Test func releasedActivityDecodes() throws {
        let json = #"""
        {"entries":[
          {"trigger":"scheduled","outcome":{"skipped":{"_0":"setupRequired"}},"startedAt":800000000,"finishedAt":800000000,"count":1},
          {"trigger":"resync","outcome":{"succeeded":{}},"startedAt":800000600,"finishedAt":800000660,"count":1},
          {"trigger":"scheduled","outcome":{"failed":{"reason":"Bisync aborted"}},"startedAt":800001200,"finishedAt":800001260,"count":1},
          {"trigger":"syncNow","outcome":{"succeeded":{}},"startedAt":800001300,"finishedAt":800001310,"count":1},
          {"trigger":"scheduled","outcome":{"skipped":{"_0":"lowDataNetwork"}},"startedAt":800001800,"finishedAt":800003000,"count":3},
          {"trigger":"scheduled","outcome":{"skipped":{"_0":"configurationUnusable"}},"startedAt":800003600,"finishedAt":800003600,"count":1},
          {"trigger":"scheduled","outcome":{"skipped":{"_0":"previousSyncRunning"}},"startedAt":800004200,"finishedAt":800004200,"count":1}
        ]}
        """#

        let log = try JSONDecoder().decode(ActivityLog.self, from: Data(json.utf8))

        #expect(log.entries.map(\.trigger) == [.scheduled, .resync, .scheduled, .syncNow, .scheduled, .scheduled, .scheduled])
        #expect(log.entries.map(\.outcome) == [
            .skipped(.setupRequired), .succeeded, .failed(reason: "Bisync aborted"), .succeeded,
            .skipped(.lowDataNetwork), .skipped(.configurationUnusable), .skipped(.previousSyncRunning),
        ])
        #expect(log.entries[4].count == 3)
        #expect(log.entries[4].finishedAt == Date(timeIntervalSinceReferenceDate: 800_003_000))
    }

    /// What the app writes now must also be what it reads back.
    @Test func currentFormatsRoundTrip() throws {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
        var log = ActivityLog()
        log.record(SyncActivity(trigger: .scheduled, outcome: .failed(reason: "multi\nline"), startedAt: date, finishedAt: date))
        log.record(SyncActivity(trigger: .scheduled, outcome: .skipped(.lowDataNetwork), startedAt: date, finishedAt: date + 600))
        log.record(SyncActivity(trigger: .scheduled, outcome: .skipped(.lowDataNetwork), startedAt: date + 600, finishedAt: date + 1200))
        let record = SyncRunRecord(startedAt: date, finishedAt: date, outcome: .failure, failureReason: nil, lastSuccessAt: nil)

        #expect(try JSONDecoder().decode(ActivityLog.self, from: JSONEncoder().encode(log)) == log)
        #expect(try JSONDecoder().decode(SyncRunRecord.self, from: JSONEncoder().encode(record)) == record)
    }
}
