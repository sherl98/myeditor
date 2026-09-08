import Foundation
import Observation

@Observable @MainActor
public final class DocumentStore {
    public private(set) var sessions: [DocumentSession] = []
    public init() {}

    public func open(_ input: URL) async throws -> DocumentSession {
        // Keep the URL returned by the picker/bookmark alive before the first
        // read. Canonicalising it must not discard its security-scoped grant.
        let accessing = input.startAccessingSecurityScopedResource()
        defer { if accessing { input.stopAccessingSecurityScopedResource() } }
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = sessions.first(where: { $0.url == url }) { return existing }
        let files = DiskFileAccess()
        let snapshot = try await files.read(url)
        // Check again after suspension: two simultaneous open requests share one session.
        if let existing = sessions.first(where: {
            $0.url == url
                || (!$0.savedSnapshot.identity.isEmpty
                    && $0.savedSnapshot.identity == snapshot.identity)
        }) {
            return existing
        }
        let session = try DocumentSession(
            url: url, snapshot: snapshot, files: files, accessURL: input)
        sessions.append(session)
        return session
    }

    public func close(_ session: DocumentSession) {
        session.close()
        sessions.removeAll { $0.id == session.id }
    }
}
