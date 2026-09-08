import Foundation
import ManuscriptCore

actor DelayedFiles: DocumentFileAccess {
    let disk = DiskFileAccess(coordinateAccess: false)
    var writesStarted = 0
    var concurrentWrites = 0
    var maximumConcurrentWrites = 0
    var recorded: [String] = []
    var failNext = false
    func read(_ url: URL) async throws -> FileSnapshot { try await disk.read(url) }
    func writeCopy(_ url: URL, source: String) async throws -> FileSnapshot {
        try await disk.writeCopy(url, source: source)
    }
    func rename(_ url: URL, to destination: URL, expectedRevision: String) async throws
        -> FileSnapshot
    {
        try await disk.rename(url, to: destination, expectedRevision: expectedRevision)
    }
    func failOneWrite() { failNext = true }
    func write(_ url: URL, source: String, expectedRevision: String) async throws -> FileSnapshot {
        writesStarted += 1
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        try await Task.sleep(for: .milliseconds(240))
        if failNext {
            failNext = false
            throw CocoaError(.fileWriteUnknown)
        }
        let snapshot = try await disk.write(url, source: source, expectedRevision: expectedRevision)
        recorded.append(source)
        return snapshot
    }
}

extension Checks {
    func saveOrdering() async throws {
        let url = try file("save-ordering")
        let files = DelayedFiles()
        let session = try DocumentSession(
            url: url, snapshot: await files.read(url), files: files, watch: false)
        defer { session.close() }
        edit(session, suffix: "第一笔。")
        let saving = Task { await session.save(.explicit) }
        try await waitUntil("First write started") { await files.writesStarted == 1 }
        edit(session, suffix: "第二笔。")
        try expect(await saving.value, "Writer drains a newer generation")
        try expect(
            try String(contentsOf: url, encoding: .utf8).contains("第一笔。第二笔。"),
            "Latest full document reaches disk")
        let concurrentWrites = await files.maximumConcurrentWrites
        let recordedWrites = await files.recorded.count
        try expect(concurrentWrites == 1 && recordedWrites == 2, "Writes are serialized")

        let beforeUndo = session.source
        edit(session, suffix: "将撤销的文本")
        let pending = Task { await session.save(.explicit) }
        try await waitUntil("Write before undo started") { await files.writesStarted >= 3 }
        replace(session, with: beforeUndo)
        try expect(
            await pending.value, "Undo to the previous saved text survives an in-flight write")
        try expect(
            !(try String(contentsOf: url, encoding: .utf8)).contains("将撤销的文本"),
            "Old completion cannot overwrite a newer undo")

        let beforeIME = session.source
        edit(session, suffix: "已确认。")
        let pendingIME = Task { await session.save(.explicit) }
        try await waitUntil("Write before composition started") { await files.writesStarted >= 5 }
        session.setComposing(true)
        replace(session, with: beforeIME + "已确认。zhongwen")
        _ = await pendingIME.value
        try expect(
            session.hasUnsavedChanges && session.isComposing,
            "Composition remains unsaved after an earlier write finishes")
        try expect(
            !(try String(contentsOf: url, encoding: .utf8)).contains("zhongwen"),
            "In-flight save never contains candidate input")
        replace(session, with: beforeIME + "已确认。中文")
        session.setComposing(false)
        try expect(
            await session.save(.composition), "Confirmed composition follows the previous write")

        await files.failOneWrite()
        edit(session, suffix: "重试内容。")
        try expect(
            !(await session.save(.explicit)) && session.hasUnsavedChanges,
            "Failed write retains full draft")
        try expect(await session.save(.explicit), "Failed generation can be retried")
        try expect(
            try String(contentsOf: url, encoding: .utf8).contains("重试内容。"),
            "Retry writes latest content")
    }
}
