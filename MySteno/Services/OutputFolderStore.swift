import AppKit
import Foundation
import OSLog

@Observable
final class OutputFolderStore {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "OutputFolder")

    private(set) var folderURL: URL?
    private(set) var errorMessage: String?

    private let bookmarkKey = "outputFolderBookmark"

    init() {
        restoreBookmark()
    }

    var displayPath: String {
        guard let folderURL else { return "Not selected" }
        return folderURL.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Transcription Output Folder"
        panel.message = "Text files created from imported audio will be saved here."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedFolder

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try saveBookmark(for: url)
            return true
        } catch {
            errorMessage = "Could not keep access to “\(url.lastPathComponent)”: \(error.localizedDescription)"
            Self.logger.error("Saving output folder bookmark failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func openFolder() {
        guard let folderURL else { return }
        NSWorkspace.shared.open(folderURL)
    }

    func beginAccess() throws -> (url: URL, securityScopeStarted: Bool) {
        guard let folderURL else { throw OutputFolderError.notSelected }
        return (folderURL, folderURL.startAccessingSecurityScopedResource())
    }

    private var suggestedFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let transcriberOutput = documents.appendingPathComponent("MySteno Output", isDirectory: true)
        return FileManager.default.fileExists(atPath: transcriberOutput.path) ? transcriberOutput : documents
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        let url: URL
        var stale = false
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            errorMessage = "The saved output folder is no longer available. Choose it again."
            Self.logger.error("Resolving output folder bookmark failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        folderURL = url
        guard stale else { return }
        do {
            try saveBookmark(for: url)
        } catch {
            Self.logger.error("Refreshing stale output folder bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        folderURL = url
        errorMessage = nil
    }
}

private enum OutputFolderError: LocalizedError {
    case notSelected

    fileprivate var errorDescription: String? {
        "Choose an output folder in Preferences before transcribing an audio file."
    }
}
