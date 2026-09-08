import Foundation

// Compile with Sources/ManuscriptCore/*.swift files.
// Reproduces the core state created by webViewWebContentProcessDidTerminate.
// Does not terminate a user's running WebKit process.
@main struct RecoveryProbe {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MyEditorRecoveryProbe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.md")
        try "# Saved\n".write(to: url, atomically: true, encoding: .utf8)
        let files = DiskFileAccess(coordinateAccess: false)
        let session = try DocumentSession(
            url: url, snapshot: await files.read(url), files: files, watch: false)
        session.setEditorReady(true)
        session.receiveEditorSource("# Saved\n\nDraft", sequence: 1, revision: 0)
        session.editorDidTerminate()
        print("hasUnsavedChanges=\(session.hasUnsavedChanges), editorReady=\(session.editorReady)")
        print("saveSucceeded=\(await session.save(.explicit))")
        do {
            _ = try await session.writeRecoveryCopy(
                to: directory.appendingPathComponent("recovery.md"))
            print("copySucceeded=true")
        } catch { print("copySucceeded=false, error=\(error.localizedDescription)") }
        print("knownDraftStillInMemory=\(session.source.contains("Draft"))")
        session.close()
    }
}
