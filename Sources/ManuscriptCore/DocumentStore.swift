import Foundation
import Observation

@Observable @MainActor
public final class DocumentStore {
    public private(set) var sessions: [DocumentSession] = []
    @ObservationIgnored private var savingDestinations: Set<URL> = []
    public init() {}

    @discardableResult public func createDocument() -> DocumentSession {
        var number = 1
        var name = "未命名"
        while sessions.contains(where: { $0.suggestedName == name }) {
            number += 1
            name = "未命名 \(number)"
        }
        let session = DocumentSession(untitledName: name)
        sessions.append(session)
        return session
    }

    public func saveFirst(_ session: DocumentSession, to destination: URL) async throws {
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        let canonical = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !savingDestinations.contains(canonical),
            !sessions.contains(where: { $0.id != session.id && $0.url == canonical })
        else { throw ManuscriptError.nameInUse }
        savingDestinations.insert(canonical)
        defer { savingDestinations.remove(canonical) }
        // Also reject hard-link aliases of a document already open in another tab.
        if let target = try? await DiskFileAccess().read(canonical),
            !target.identity.isEmpty,
            sessions.contains(where: {
                $0.id != session.id && $0.savedSnapshot.identity == target.identity
            })
        {
            throw ManuscriptError.nameInUse
        }
        try await session.saveFirst(to: destination)
    }

    public func open(_ input: URL) async throws -> DocumentSession {
        // Keep the URL returned by the picker/bookmark alive before the first
        // read. Canonicalising it must not discard its security-scoped grant.
        let accessing = input.startAccessingSecurityScopedResource()
        defer { if accessing { input.stopAccessingSecurityScopedResource() } }
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        guard !savingDestinations.contains(url) else { throw ManuscriptError.operationInProgress }
        if let existing = sessions.first(where: { $0.url == url }) { return existing }
        let files = DiskFileAccess()
        let snapshot = try await files.read(url)
        guard !savingDestinations.contains(url) else { throw ManuscriptError.operationInProgress }
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
