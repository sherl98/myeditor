import Foundation
import ManuscriptCore

private actor DraftFiles: DocumentFileAccess {
    let disk = DiskFileAccess(coordinateAccess: false)
    var reads = 0
    var copies = 0
    var writes = 0
    var failCopy = false
    func failNextCopy() { failCopy = true }
    func read(_ url: URL) async throws -> FileSnapshot {
        reads += 1
        return try await disk.read(url)
    }
    func write(_ url: URL, source: String, expectedRevision: String) async throws -> FileSnapshot {
        writes += 1
        return try await disk.write(url, source: source, expectedRevision: expectedRevision)
    }
    func writeCopy(_ url: URL, source: String) async throws -> FileSnapshot {
        copies += 1
        try await Task.sleep(for: .milliseconds(180))
        if failCopy {
            failCopy = false
            throw CocoaError(.fileWriteUnknown)
        }
        return try await disk.writeCopy(url, source: source)
    }
    func rename(_ url: URL, to destination: URL, expectedRevision: String) async throws
        -> FileSnapshot
    {
        try await disk.rename(url, to: destination, expectedRevision: expectedRevision)
    }
}

extension Checks {
    func newDocuments() async throws {
        let files = DraftFiles()
        let draft = DocumentSession(untitledName: "未命名", files: files)
        defer { draft.close() }
        draft.setEditorReady(true)
        try expect(
            draft.url == nil && draft.isEditing && draft.statusText == "尚未保存",
            "A blank draft is editable without a file URL")
        replace(draft, with: "# 新文稿\n\n中文API与 emoji 👩🏽‍💻。\n")
        draft.updateHistory(canUndo: true, canRedo: false)
        for reason in [SaveReason.idle, .focusLoss, .navigation, .done, .close, .explicit] {
            try expect(
                !(await draft.save(reason)), "An untitled save cannot report a persisted file")
        }
        await draft.checkExternalChanges()
        try await Task.sleep(for: .milliseconds(950))
        let operations = await (files.reads, files.copies, files.writes)
        try expect(
            operations == (0, 0, 0),
            "Draft idle, close, navigation and external checks perform no disk I/O")
        try expect(
            await draft.finishEditing() && draft.hasUnsavedChanges,
            "Finishing editing keeps the unsaved draft")
        draft.beginEditing()
        let destination = directory.appendingPathComponent("first-save.md")
        await files.failNextCopy()
        do {
            try await draft.saveFirst(to: destination)
            throw CheckFailure(description: "First write should fail")
        } catch let error as CheckFailure { throw error } catch {}
        try expect(
            draft.isUntitled && draft.hasUnsavedChanges
                && !FileManager.default.fileExists(atPath: destination.path),
            "First-save failure preserves the draft and never adopts a path")
        draft.setComposing(true)
        do {
            try await draft.saveFirst(to: destination)
            throw CheckFailure(description: "Uncommitted IME input must not be saved")
        } catch ManuscriptError.composing {}
        draft.setComposing(false)
        let revision = draft.documentRevision
        let firstSave = Task { try await draft.saveFirst(to: destination) }
        try await waitUntil("First save starts") { await files.copies == 2 }
        replace(draft, with: draft.source + "写入期间的新内容。")
        do {
            try await draft.saveFirst(to: directory.appendingPathComponent("duplicate-save.md"))
            throw CheckFailure(description: "Concurrent first saves must not create two files")
        } catch ManuscriptError.operationInProgress {}
        try await firstSave.value
        try expect(
            draft.url == destination && draft.canUndo && draft.documentRevision == revision,
            "First save adopts the path while preserving editor identity and history")
        try await waitUntil("Later generation auto-saves after first save") {
            !draft.hasUnsavedChanges
        }
        try expect(
            try String(contentsOf: destination, encoding: .utf8) == draft.source,
            "Newer input is not cleared by the first write completion")
        let writeCount = await files.writes
        try expect(writeCount > 0, "Autosave begins after successful first save")

        let blank = DocumentSession(
            untitledName: "空白", files: DiskFileAccess(coordinateAccess: false))
        defer { blank.close() }
        let blankURL = directory.appendingPathComponent("blank-new.md")
        try await blank.saveFirst(to: blankURL)
        try expect(
            try Data(contentsOf: blankURL).isEmpty && !blank.isUntitled,
            "An untouched blank document creates a zero-byte Markdown file")

        let store = DocumentStore()
        let first = store.createDocument()
        let second = store.createDocument()
        defer { for session in store.sessions { store.close(session) } }
        try expect(
            first.displayName == "未命名" && second.displayName == "未命名 2",
            "New drafts receive distinct names")
        let opened = try await store.open(destination)
        do {
            try await store.saveFirst(first, to: destination)
            throw CheckFailure(description: "An open document must not be overwritten by a draft")
        } catch ManuscriptError.nameInUse {}
        try expect(
            first.isUntitled && opened.source == draft.source,
            "Destination collision preserves both documents")
        try await second.rename(to: "下一章")
        try expect(
            second.displayName == "下一章" && second.isUntitled,
            "Renaming a draft only changes its suggested name")
        store.close(second)
        try expect(
            second.isClosed && second.url == nil,
            "Discarding a draft never creates or deletes a disk file")
    }
}
