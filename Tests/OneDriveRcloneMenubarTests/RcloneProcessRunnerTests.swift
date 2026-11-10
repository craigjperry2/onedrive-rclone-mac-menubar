import Foundation
import Testing
@testable import OneDriveRcloneMenubar

/// The contract with the rclone executable, checked against shell scripts that
/// stand in for it: what the app runs, and how it reads what rclone reports.
struct RcloneProcessRunnerTests {
    let directory: TemporaryDirectory
    let configPath: String

    init() throws {
        directory = try TemporaryDirectory()
        let config = directory.url.appending(path: "rclone.conf")
        try Data("[onedrive]\ntype = alias\n".utf8).write(to: config)
        configPath = config.path(percentEncoded: false)
    }

    func settings(rclone script: String) throws -> SyncSettings {
        let rclone = try makeExecutableScript(script, at: directory.url.appending(path: "bin/rclone"))
        return SyncSettings(rcloneExecutablePath: rclone.path(percentEncoded: false), configPath: configPath, remoteName: "onedrive", localPath: directory.url.appending(path: "local").path(percentEncoded: false), intervalSeconds: 600)
    }

    var transcript: URL { directory.url.appending(path: "Application Support/latest-run.log") }

    // MARK: Validation

    @Test func validationFindsOnlyTheExactRemote() async throws {
        let listing = """
        #!/bin/sh
        [ "$1" = listremotes ] || exit 9
        echo 'NOTICE: Config file "/somewhere/rclone.conf" not found - using defaults' >&2
        echo 'onedrive-work:'
        echo 'my onedrive:'
        echo 'onedrive2:'
        """
        #expect(await RcloneProcessRunner().validate(try settings(rclone: listing)) == SyncSettings.readyToSetUp)
        #expect(await RcloneProcessRunner().validate(try settings(rclone: listing + "\necho 'onedrive:'")) == nil)
    }

    @Test func validationPointsRcloneAtTheConfiguredConfigFile() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        [ "$RCLONE_CONFIG" = '\(configPath)' ] && echo 'onedrive:'
        """)

        #expect(await RcloneProcessRunner().validate(settings) == nil)
    }

    @Test func unreadableRcloneConfigurationIsReported() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        echo 'Failed to load config file: parse error' >&2
        exit 1
        """)

        #expect(await RcloneProcessRunner().validate(settings) == "Unable to read the rclone configuration.")
    }

    @Test func validationFindsTheRemoteAmongManyRemotes() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        echo 'onedrive:'
        i=1
        while [ "$i" -le 40 ]; do echo "other$i:"; i=$((i + 1)); done
        """)

        await withKnownIssue("validate and hasRemote only search the last 30 lines of `rclone listremotes`") {
            #expect(await RcloneProcessRunner().validate(settings) == nil)
            #expect(await RcloneProcessRunner().hasRemote(settings))
        }
    }

    // MARK: Syncing

    @Test func scheduledSyncsNeverResyncAndAlwaysCheckAccess() async throws {
        let settings = try settings(rclone: "#!/bin/sh\nprintf 'arg=%s\\n' \"$@\"\n")

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == 0)
        #expect(Array(result.lines.prefix(3)) == ["arg=bisync", "arg=onedrive:", "arg=\(settings.localPath)"])
        #expect(!result.lines.contains("arg=--resync"))
        #expect(result.lines.contains("arg=--check-access"))
        #expect(result.lines.contains("arg=--exclude=/Personal Vault/**"))
    }

    @Test func largeOutputKeepsTheEndAndBoundsTheTranscript() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        i=1
        while [ "$i" -le 5000 ]; do echo "NOTICE: a fairly long line of rclone output number $i"; i=$((i + 1)); done
        printf 'ERROR : Bisync critical error: final line without newline'
        exit 2
        """)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == 2)
        #expect(result.lines.count == 30)
        #expect(result.failureReason == "Bisync critical error: final line without newline")
        #expect(try Data(contentsOf: transcript).count <= TranscriptStore.maximumStoredBytes)
        #expect(TranscriptStore(fileURL: transcript).displayLines() == result.lines)
    }

    /// The reason names the problem from all of rclone's output, not its generic last line.
    @Test func failureReasonNamesTheProblem() async throws {
        let output = RcloneOutput.checkFileMissingOnOneDrive.joined(separator: "\n")
        let settings = try settings(rclone: "#!/bin/sh\ncat <<'OUTPUT'\n\(output)\nOUTPUT\nexit 7\n")

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.lines.last == "2026/11/09 21:26:30 NOTICE: Failed to bisync: bisync aborted")
        #expect(result.failureReason == "The RCLONE_TEST check file is missing from OneDrive")
    }

    /// rclone 1.75 colours bisync's messages even when its output is a pipe, unless
    /// it is given `--color NEVER`.
    @Test func displayedOutputHasNoTerminalColourCodes() async throws {
        let settings = try settings(rclone: #"""
        #!/bin/sh
        red='\033[31m' reset='\033[0m'
        while [ $# -gt 0 ]; do
          [ "$1" = --color ] && [ "$2" = NEVER ] && red= reset=
          shift
        done
        printf '2026/11/09 04:48:41 ERROR : %bBisync aborted. Must run --resync to recover.%b\n' "$red" "$reset"
        exit 7
        """#)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.lines == ["2026/11/09 04:48:41 ERROR : Bisync aborted. Must run --resync to recover."])
        #expect(try String(contentsOf: transcript, encoding: .utf8) == "2026/11/09 04:48:41 ERROR : Bisync aborted. Must run --resync to recover.\n")
    }

    /// rclone logs its final stats at INFO, which the default NOTICE level hides.
    @Test func successfulRunsLogWhatTheyChanged() async throws {
        let settings = try settings(rclone: #"""
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = --stats-log-level ] && [ "$2" = NOTICE ]; then
            echo '2026/11/09 21:27:14 NOTICE: '
            printf 'Transferred:   \t          4 B / 4 B, 100%%, 0 B/s, ETA -\n'
            echo 'Deleted:                1 (files), 0 (dirs), 3 B (freed)'
            echo 'Transferred:            2 / 2, 100%'
            echo 'Elapsed time:         0.0s'
          fi
          shift
        done
        """#)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == 0)
        #expect(RunOutput(lines: TranscriptStore(fileURL: transcript).displayLines()).successSummary == "Succeeded: copied 2 files, deleted 1 file")
    }

    @Test func versionIsTheFirstLineOfRcloneVersion() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        [ "$1" = version ] || exit 9
        echo 'rclone v1.75.2'
        echo '- os/version: darwin 27.2 (64 bit)'
        echo '- go/version: go1.25.4'
        """)

        #expect(await RcloneProcessRunner().version(settings) == "rclone v1.75.2")
        #expect(await RcloneProcessRunner().version(try self.settings(rclone: "#!/bin/sh\nexit 1\n")) == nil)
    }

    @Test func killedRcloneIsAFailure() async throws {
        let settings = try settings(rclone: "#!/bin/sh\nkill -9 $$\n")

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode != 0)
    }

    @Test func eachRunReplacesThePreviousTranscript() async throws {
        let failing = try settings(rclone: "#!/bin/sh\necho 'first run failed'\nexit 1\n")
        _ = await RcloneProcessRunner().run(.sync, settings: failing, transcriptURL: transcript)
        let quiet = try settings(rclone: "#!/bin/sh\nexit 0\n")

        let result = await RcloneProcessRunner().run(.sync, settings: quiet, transcriptURL: transcript)

        #expect(result.lines.isEmpty)
        #expect(TranscriptStore(fileURL: transcript).displayLines().isEmpty)
    }

    @Test func unwritableTranscriptStopsTheRunWithAReason() async throws {
        let settings = try settings(rclone: "#!/bin/sh\ntouch \"$0.ran\"\n")
        // A directory where the transcript file should be cannot be opened for writing.
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == -1)
        #expect(result.failureReason == "Unable to create the rclone output log.")
        #expect(!FileManager.default.fileExists(atPath: settings.rcloneExecutablePath + ".ran"))
    }

    @Test func rcloneWithoutExecutePermissionFailsToLaunch() async throws {
        let settings = try settings(rclone: "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.rcloneExecutablePath)

        let result = await RcloneProcessRunner().run(.sync, settings: settings, transcriptURL: transcript)

        #expect(result.exitCode == -1)
        #expect(result.failureReason?.isEmpty == false)
    }

    // MARK: Guided setup

    @Test func refusedSignInReportsWhatRcloneSaid() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        [ "$*" = 'config create onedrive onedrive --no-output' ] || { echo "unexpected: $*"; exit 9; }
        echo 'NOTICE: Waiting for code...'
        echo 'ERROR: Failed to create onedrive remote: failed to get token: access_denied'
        exit 1
        """)

        let failure = await RcloneProcessRunner().authorize(settings) { _ in }

        #expect(failure == "Failed to create onedrive remote: failed to get token: access_denied")
    }

    @Test func remoteCheckFileIsCreatedAtTheRootOfTheRemote() async throws {
        let settings = try settings(rclone: """
        #!/bin/sh
        [ "$*" = 'touch onedrive:RCLONE_TEST' ] || { echo "unexpected: $*"; exit 9; }
        """)

        #expect(await RcloneProcessRunner().createRemoteCheckFile(settings) == nil)
    }

    @Test(arguments: [
        ("NOTICE: If your browser doesn't open automatically go to the following link: http://127.0.0.1:53682/auth?state=abc_DEF-12", "http://127.0.0.1:53682/auth?state=abc_DEF-12"),
        ("go to: http://127.0.0.1:1234/auth?state=xyz\".", "http://127.0.0.1:1234/auth?state=xyz"),
        ("NOTICE: Make sure your Redirect URL is set to \"http://localhost:53682/\" in your custom config.", nil),
        ("http://127.0.0.1:53682/auth", nil),
        ("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?state=abc", nil),
    ] as [(String, String?)])
    func signInLinkIsFoundInRcloneOutput(output: String, expected: String?) {
        #expect(RcloneProcessRunner.signInURL(in: output) == expected.flatMap(URL.init(string:)))
    }
}
