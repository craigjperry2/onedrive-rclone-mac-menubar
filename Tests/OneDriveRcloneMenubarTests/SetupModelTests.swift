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

    @Test func checkAgainFindsRcloneInstalledWhileSetupIsOpen() async throws {
        let harness = try Harness(localPath: "")
        try harness.saveSettings { $0.rcloneExecutablePath = "" }
        let rclone = harness.root.appending(path: "nix-profile/bin/rclone").path(percentEncoded: false)
        harness.rcloneCandidates = [rclone]
        let model = SetupModel(coordinator: harness.makeCoordinator(), home: harness.root)
        await model.start()
        #expect(model.step == .rcloneMissing)

        try harness.installRclone(at: rclone)
        await model.start()

        #expect(model.step == .connect)
    }

    @Test func refusedSignInExplainsWhyAndCanBeRetried() async throws {
        let harness = try Harness(localPath: "")
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        await model.start()

        model.signIn()
        try await waitUntil { await harness.runner.isWaitingForAuthorization }
        await harness.runner.finishAuthorization(failure: "ERROR: Failed to create onedrive remote: access_denied")
        try await waitUntil { model.step == .connect }

        #expect(!model.isConnected)
        #expect(model.message == "OneDrive is not configured yet: ERROR: Failed to create onedrive remote: access_denied")
        model.signIn()
        #expect(model.step == .signingIn)
        #expect(model.message == nil)
        model.close()
    }

    @Test func chooseFolderRefusalKeepsTheEarlierChoice() async throws {
        let harness = try Harness(localPath: "")
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        let folder = harness.root.appending(path: "OneDrive", directoryHint: .isDirectory)

        model.chooseFolder(folder)
        model.chooseFolder(harness.root.appending(path: "Library/OneDrive"))

        #expect(model.localFolder == folder)
        #expect(model.message == "Choose a folder outside your Library folder.")
    }

    @Test func failedRemoteCheckFileStopsSetupBeforeAnythingIsSaved() async throws {
        let harness = try Harness(localPath: "")
        await harness.coordinator.load()
        await harness.runner.finishAuthorization(failure: nil)
        await harness.runner.setRemoteCheckFileFailure("ERROR : RCLONE_TEST: Failed to touch: 403 Forbidden")
        let model = try await confirmedSetup(harness, folder: "OneDrive")

        await model.startFirstSync()

        #expect(model.step == .firstSyncFailed(reason: "ERROR : RCLONE_TEST: Failed to touch: 403 Forbidden"))
        #expect(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load()?.localPath == "")
        #expect(await harness.runner.runs.isEmpty)
    }

    @Test func failedFirstSyncShowsWhatRcloneReported() async throws {
        let harness = try Harness(localPath: "")
        await harness.coordinator.load()
        await harness.runner.finishAuthorization(failure: nil)
        await harness.runner.setExitCode(7, lastLine: "ERROR : Bisync critical error: path1 and path2 are the same")
        let model = try await confirmedSetup(harness, folder: "OneDrive")

        await model.startFirstSync()

        #expect(model.step == .firstSyncFailed(reason: "ERROR : Bisync critical error: path1 and path2 are the same"))
        #expect(harness.coordinator.status == .unhealthy(reason: "ERROR : Bisync critical error: path1 and path2 are the same"))
    }

    /// Setup writes only localPath, so an empty rclone path keeps finding rclone
    /// wherever it is installed instead of pinning a Nix store path.
    @Test func setupSavesOnlyTheFolderAndKeepsFilesAlreadyThere() async throws {
        let harness = try Harness(localPath: "")
        try harness.saveSettings { $0.rcloneExecutablePath = ""; $0.intervalSeconds = 900 }
        harness.rcloneCandidates = ["/bin/sh"]
        let coordinator = harness.makeCoordinator()
        await coordinator.load()
        await harness.runner.finishAuthorization(failure: nil)
        let folder = harness.root.appending(path: "Existing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: folder.appending(path: "RCLONE_TEST"))
        try Data("notes".utf8).write(to: folder.appending(path: "notes.txt"))
        let model = SetupModel(coordinator: coordinator, home: harness.root)
        await model.start()
        model.continueToFolder()
        model.chooseFolder(folder)
        model.continueToFirstSync()

        await model.startFirstSync()

        #expect(model.step == .finished)
        let saved = try #require(try JSONFileStore<SyncSettings>(fileURL: harness.paths.settingsFile).load())
        #expect(saved == SyncSettings(rcloneExecutablePath: "", configPath: harness.settings.configPath, remoteName: "onedrive", localPath: try #require(model.localPath), intervalSeconds: 900))
        #expect(try Data(contentsOf: folder.appending(path: "RCLONE_TEST")) == Data("keep me".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "notes.txt")) == Data("notes".utf8))
    }

    private func confirmedSetup(_ harness: Harness, folder name: String) async throws -> SetupModel {
        let model = SetupModel(coordinator: harness.coordinator, home: harness.root)
        await model.start()
        model.continueToFolder()
        model.chooseFolder(harness.root.appending(path: name, directoryHint: .isDirectory))
        model.continueToFirstSync()
        try #require(model.step == .confirmFirstSync)
        return model
    }
}
