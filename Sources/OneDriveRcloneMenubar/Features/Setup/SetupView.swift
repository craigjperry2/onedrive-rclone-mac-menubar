import AppKit
import SwiftUI

struct SetupView: View {
    @StateObject private var model: SetupModel
    @Environment(\.dismiss) private var dismiss

    init(coordinator: SyncCoordinator) {
        _model = StateObject(wrappedValue: SetupModel(coordinator: coordinator))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            content
            if let message = model.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 360)
        .task { await model.start() }
        .onDisappear { model.close() }
    }

    private var title: String {
        switch model.step {
        case .checking, .rcloneMissing: "Set Up OneDrive Sync"
        case .connect, .signingIn: "Connect Your OneDrive"
        case .chooseFolder: "Choose a Folder on This Mac"
        case .confirmFirstSync: "Before the First Sync"
        case .firstSyncRunning: "Running the First Sync…"
        case .finished: "OneDrive Sync Is Set Up"
        case .firstSyncFailed: "The First Sync Did Not Finish"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .checking:
            ProgressView().controlSize(.small)
        case .rcloneMissing:
            paragraph("OneDrive Sync uses rclone to copy files, and rclone is not installed on this Mac. Setup can continue once it is.")
            paragraph("Install it with Homebrew by running brew install rclone in Terminal, or add rclone to your Nix configuration. Then choose Check Again.")
        case .connect:
            if model.isConnected {
                paragraph("OneDrive is already connected in rclone. Continue to choose the folder to sync, or sign in again to use a different Microsoft account.")
            } else {
                paragraph("Sign in to your Microsoft account in your web browser and allow rclone to access your OneDrive. rclone stores the access it is given in its own configuration file on this Mac.")
            }
        case .signingIn:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to sign in to Microsoft in your browser…")
            }
            paragraph("When the browser says you can close it, come back here. Choose Cancel to stop without connecting.")
            if let url = model.signInURL {
                Link("Open the sign-in page again", destination: url)
            }
        case .chooseFolder:
            Label("OneDrive is connected.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            paragraph("Choose the folder on this Mac that will hold a copy of your OneDrive. You can choose an empty folder or create a new one.")
            HStack {
                Image(systemName: "folder")
                Text(model.localPath ?? "No folder chosen")
                    .foregroundStyle(model.localFolder == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…", action: chooseFolder)
            }
        case .confirmFirstSync:
            let folder = model.localPath ?? ""
            paragraph("The first sync makes OneDrive and \(folder) match:")
            VStack(alignment: .leading, spacing: 6) {
                bullet("Files that are only in OneDrive are copied to the folder.")
                bullet("Files that are only in the folder are uploaded to OneDrive.")
                bullet("If a file is in both places with different contents, the OneDrive version replaces the one in the folder.")
                bullet("Nothing is deleted on either side.")
            }
            paragraph("A small file named RCLONE_TEST is added to both sides first; every sync checks it to make sure both are reachable. Nothing changes until you choose Start First Sync.")
        case .firstSyncRunning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Copying files between OneDrive and your folder…")
            }
            paragraph("A large OneDrive can take a while. You can close this window; the sync carries on, and the menu bar icon shows its progress.")
        case .finished:
            paragraph("\(model.localPath ?? "Your folder") now syncs with OneDrive automatically while this Mac is on. The menu bar icon shows how syncing is going:")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SyncStatus.legend, id: \.title) { status in
                    Label {
                        Text("\(Text(status.title).bold()): \(status.meaning)").fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: status.symbolName)
                    }
                }
            }
        case let .firstSyncFailed(reason):
            paragraph(reason)
            paragraph("OneDrive and your folder are set up, but they are not in sync yet. Open the menu bar icon to see rclone's output, then choose Resync… to try again.")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.step {
        case .checking:
            Button("Cancel") { dismiss() }
        case .rcloneMissing:
            Button("Cancel") { dismiss() }
            Button("Check Again") { Task { await model.start() } }.keyboardShortcut(.defaultAction)
        case .connect:
            Button("Cancel") { dismiss() }
            if model.isConnected {
                Button("Sign In Again…") { model.signIn() }
                Button("Continue") { model.continueToFolder() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Sign In with Microsoft…") { model.signIn() }.keyboardShortcut(.defaultAction)
            }
        case .signingIn:
            Button("Cancel") { model.cancelSignIn() }
        case .chooseFolder:
            Button("Back") { model.back() }
            Button("Continue") { model.continueToFirstSync() }.keyboardShortcut(.defaultAction)
        case .confirmFirstSync:
            Button("Cancel Setup") { dismiss() }
            Button("Back") { model.back() }
            Button("Start First Sync") { Task { await model.startFirstSync() } }.keyboardShortcut(.defaultAction)
        case .firstSyncRunning, .finished, .firstSyncFailed:
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        Label { paragraph(text) } icon: { Image(systemName: "circle.fill").font(.system(size: 5)) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder to sync with OneDrive"
        if panel.runModal() == .OK, let url = panel.url { model.chooseFolder(url) }
    }
}
