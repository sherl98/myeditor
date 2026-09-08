import Darwin
import Foundation

public struct FileSnapshot: Sendable, Equatable {
    public let source: String
    public let revision: String
    public let identity: String

    public init(source: String, identity: String = "") {
        self.source = source
        self.revision = ManuscriptCodec.revision(source)
        self.identity = identity
    }
}

public protocol DocumentFileAccess: Sendable {
    func read(_ url: URL) async throws -> FileSnapshot
    func write(_ url: URL, source: String, expectedRevision: String) async throws -> FileSnapshot
    func writeCopy(_ url: URL, source: String) async throws -> FileSnapshot
    func rename(_ url: URL, to destination: URL, expectedRevision: String) async throws
        -> FileSnapshot
}

/// One service per document. No file I/O runs on the UI actor.
public actor DiskFileAccess: DocumentFileAccess {
    private let coordinateAccess: Bool
    /// Isolated fixtures exercise the same atomic writer without the coordination daemon.
    public init(coordinateAccess: Bool = true) { self.coordinateAccess = coordinateAccess }

    public func read(_ url: URL) throws -> FileSnapshot { try Self.readFile(url) }

    public func write(_ url: URL, source: String, expectedRevision: String) throws -> FileSnapshot {
        try coordinateWrite(
            url, source: source, expectedRevision: expectedRevision, allowCreation: false)
    }

    public func writeCopy(_ url: URL, source: String) throws -> FileSnapshot {
        let expected =
            FileManager.default.fileExists(atPath: url.path) ? try Self.readFile(url).revision : nil
        return try coordinateWrite(
            url, source: source, expectedRevision: expected, allowCreation: true)
    }

    public func rename(_ url: URL, to destination: URL, expectedRevision: String) throws
        -> FileSnapshot
    {
        guard url.deletingLastPathComponent() == destination.deletingLastPathComponent() else {
            throw ManuscriptError.invalidName
        }
        if !coordinateAccess {
            return try Self.moveFile(url, to: destination, expectedRevision: expectedRevision)
        }
        var coordinationError: NSError?
        var result: Result<FileSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url, options: .forMoving, writingItemAt: destination, options: [],
            error: &coordinationError
        ) { source, target in
            result = Result {
                let snapshot = try Self.moveFile(
                    source, to: target, expectedRevision: expectedRevision)
                coordinator.item(at: source, didMoveTo: target)
                return snapshot
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private static func moveFile(_ source: URL, to destination: URL, expectedRevision: String)
        throws -> FileSnapshot
    {
        let snapshot = try readFile(source)
        guard snapshot.revision == expectedRevision else { throw ManuscriptError.sourceChanged }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw ManuscriptError.nameInUse }
        guard fm.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
            throw ManuscriptError.notWritable
        }
        // FileManager refuses to replace a destination created after the check.
        // A same-directory move retains the original bytes, metadata and identity.
        do { try fm.moveItem(at: source, to: destination) } catch let error as CocoaError
            where error.code == .fileWriteFileExists
        { throw ManuscriptError.nameInUse }
        return snapshot
    }

    private static func readFile(_ url: URL) throws -> FileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManuscriptError.missingFile
        }
        let data = try Data(contentsOf: url)
        let source = try ManuscriptCodec.sourceFromUTF8(data)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        return .init(source: source, identity: "\(device):\(inode)")
    }

    private func coordinateWrite(
        _ url: URL, source: String, expectedRevision: String?, allowCreation: Bool
    ) throws -> FileSnapshot {
        if !coordinateAccess {
            return try Self.replaceFile(
                url, source: source, expectedRevision: expectedRevision,
                allowCreation: allowCreation)
        }
        var coordinationError: NSError?
        var result: Result<FileSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            result = Result {
                try Self.replaceFile(
                    target, source: source, expectedRevision: expectedRevision,
                    allowCreation: allowCreation)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    private static func replaceFile(
        _ target: URL, source: String, expectedRevision: String?, allowCreation: Bool
    ) throws -> FileSnapshot {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: target.path)
        guard existed || allowCreation else { throw ManuscriptError.missingFile }
        let permissions =
            existed
            ? (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
                .uint16Value : nil
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
            !existed
                || (fm.isWritableFile(atPath: target.path) && (permissions ?? 0o600) & 0o222 != 0)
        else {
            throw ManuscriptError.notWritable
        }
        if let expectedRevision, try readFile(target).revision != expectedRevision {
            throw ManuscriptError.sourceChanged
        }
        if expectedRevision == nil && existed { throw ManuscriptError.sourceChanged }

        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).novelreader-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard
            fm.createFile(
                atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: permissions ?? 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data(source.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // A second comparison narrows the race with writers that do not use NSFileCoordinator.
        // A missing original is never recreated by the regular save path.
        if let expectedRevision {
            guard try readFile(target).revision == expectedRevision else {
                throw ManuscriptError.sourceChanged
            }
            _ = try fm.replaceItemAt(
                target, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            guard !fm.fileExists(atPath: target.path) else { throw ManuscriptError.sourceChanged }
            try fm.moveItem(at: temporary, to: target)
        }
        let committed = try readFile(target)
        guard committed.source == source else { throw ManuscriptError.sourceChanged }
        return committed
    }
}
