import Foundation
import Testing
@testable import OneDriveRcloneMenubar

@MainActor
struct SetupModelTests {
    @Test func setupStopsAndExplainsWhenRcloneIsMissing() async throws {
        let harness = try Harness(localPath: "")
        var settings = harness.settings
        settings.rcloneExecutablePath = ""
        try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).save(settings)
        let model = SetupModel(coordinator: harness.makeCoordinator(), home: harness.root)

        await model.start()
        model.signIn()

        #expect(model.step == .rcloneMissing)
        #expect(await harness.runner.authorizeCalls == 0)
    }

    @Test func cancelledSignInLeavesSetupIncompleteAndCompletedSignInIsRecorded() async throws {
        let harness = try Harness(localPath: "")
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        await model.start()
        #expect(model.step == .connect)
        #expect(!model.isConnected)

        model.signIn()
        try await waitUntil { await harness.runner.isWaitingForAuthorization }
        #expect(model.step == .signingIn)
        model.cancelSignIn()
        try await waitUntil { model.step == .connect }

        #expect(!model.isConnected)
        #expect(model.message?.contains("not configured yet") == true)
        #expect(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load() == harness.settings)

        model.signIn()
        try await waitUntil { await harness.runner.isWaitingForAuthorization }
        try await waitUntil { model.signInURL != nil }
        await harness.runner.finishAuthorization(failure: nil)
        try await waitUntil { model.step == .chooseFolder }

        #expect(model.isConnected)
        #expect(model.message == nil)
    }

    @Test func alreadyConnectedOneDriveSkipsSignIn() async throws {
        let harness = try Harness(localPath: "")
        await harness.runner.finishAuthorization(failure: nil)
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)

        await model.start()
        model.continueToFolder()

        #expect(model.step == .chooseFolder)
        #expect(await harness.runner.authorizeCalls == 0)
    }

    @Test func setupCannotContinueWithoutAFolder() async throws {
        let harness = try Harness(localPath: "")
        await harness.runner.finishAuthorization(failure: nil)
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        await model.start()
        model.continueToFolder()

        model.continueToFirstSync()

        #expect(model.step == .chooseFolder)
        #expect(model.message == "Choose a local folder to finish setup.")
    }

    @Test func finishingSetupInitialisesBisyncSoScheduledSyncsWork() async throws {
        let harness = try Harness(localPath: "")
        await harness.coordinator.load()
        await harness.runner.finishAuthorization(failure: nil)
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        let folder = harness.root.appending(path: "OneDrive-Rclone", directoryHint: .isDirectory)
        await model.start()
        model.continueToFolder()
        model.chooseFolder(folder)
        model.continueToFirstSync()

        // Nothing has changed before the user confirms the first sync.
        #expect(model.step == .confirmFirstSync)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
        #expect(await harness.runner.remoteCheckFiles == 0)
        #expect(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load()?.localPath == "")
        #expect(harness.coordinator.status == .disabled(reason: SyncSettings.readyToSetUp))

        await model.startFirstSync()

        #expect(model.step == .finished)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "RCLONE_TEST").path(percentEncoded: false)))
        #expect(await harness.runner.remoteCheckFiles == 1)
        #expect(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load()?.localPath == harness.root.appending(path: "OneDrive-Rclone").path(percentEncoded: false))
        #expect(await harness.runner.runs == [.resync])
        #expect(harness.coordinator.status == .healthy(lastSuccess: harness.clock.now))

        await harness.scheduler.fire()
        #expect(await harness.runner.runs == [.resync, .sync])
    }

    @Test func foldersThatWouldSyncTooMuchAreRefused() {
        let home = URL(filePath: "/Users/alex", directoryHint: .isDirectory)
        func problem(_ path: String) -> String? { SetupModel.folderProblem(URL(filePath: path), home: home) }

        #expect(problem("/Users/alex/OneDrive-Rclone") == nil)
        #expect(problem("/Users/alex/Documents/OneDrive") == nil)
        #expect(problem("/Volumes/Backup/OneDrive") == nil)
        #expect(problem("/Users/alex") != nil)
        #expect(problem("/Users/alex/") != nil)
        #expect(problem("/Users/alexandra/OneDrive") != nil)
        #expect(problem("/Users/alex/Library/OneDrive") != nil)
        #expect(problem("/Volumes/Backup") != nil)
        #expect(problem("/") != nil)
        #expect(problem("/Applications/OneDrive") != nil)
    }
}
