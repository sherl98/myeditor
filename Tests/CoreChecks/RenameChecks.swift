import Foundation
import ManuscriptCore

extension Checks {
    func renaming() async throws {
        let original = "\u{FEFF}# 中文标题\r\n\r\n原始正文。\r\n"
        let session = try await session("重命名前", source: original, watch: true)
        defer { session.close() }
        session.beginEditing()
        // A clean document can retain real history after an edit is undone.
        // Merely receiving a selection-only history flag is no longer enough.
        let untouched = session.source
        edit(session, suffix: "temporary edit")
        replace(session, with: untouched)
        session.updateHistory(canUndo: true, canRedo: true)
        let oldURL = session.url
        let identity = session.id
        let revision = session.documentRevision
        try await session.rename(to: "中文新名称")
        try expect(
            session.url.lastPathComponent == "中文新名称.md"
                && !FileManager.default.fileExists(atPath: oldURL.path),
            "Rename changes the source path without making a copy")
        try expect(
            try Data(contentsOf: session.url) == Data(original.utf8)
                && session.successfulSaveCount == 0,
            "A clean rename preserves bytes, BOM and CRLF without rewriting")
        try expect(
            session.id == identity && session.documentRevision == revision && session.isEditing
                && session.canUndo && session.canRedo,
            "Rename retains the document, editing state and history")
        edit(session, suffix: "重命名后继续编辑。")
        try expect(await session.save(.explicit), "The next save uses the renamed file")
        try expect(
            try String(contentsOf: session.url, encoding: .utf8).contains("重命名后继续编辑。")
                && !FileManager.default.fileExists(atPath: oldURL.path),
            "Saving never recreates the old filename")

        let collision = try file("已存在", source: "必须保留的另一份文档。")
        let currentURL = session.url
        do {
            try await session.rename(to: "已存在.md")
            throw CheckFailure(description: "A duplicate filename must be rejected")
        } catch ManuscriptError.nameInUse {}
        try expect(
            session.url == currentURL
                && (try String(contentsOf: collision, encoding: .utf8)) == "必须保留的另一份文档。",
            "A duplicate filename preserves both documents")
        do {
            try await session.rename(to: "../越界")
            throw CheckFailure(
                description: "A filename must not move the file to another directory")
        } catch ManuscriptError.invalidName {}
        try expect(session.url == currentURL, "Invalid names leave the file in place")

        let external = "# 外部新内容\n\n重命名后的监听正常。\n"
        try external.write(to: session.url, atomically: true, encoding: .utf8)
        try await waitUntil("The watcher follows the renamed path") { session.source == external }

        let delayed = DelayedFiles()
        let pendingURL = try file("待保存再重命名")
        let pending = try DocumentSession(
            url: pendingURL, snapshot: await delayed.read(pendingURL), files: delayed, watch: false)
        defer { pending.close() }
        pending.setEditorReady(true)
        edit(pending, suffix: "保存中的输入。")
        let saving = Task { await pending.save(.explicit) }
        try await waitUntil("Write is in flight before rename") { await delayed.writesStarted == 1 }
        try await pending.rename(to: "保存完成后的名称")
        try expect(
            await saving.value
                && (try String(contentsOf: pending.url, encoding: .utf8)).contains("保存中的输入。"),
            "Rename waits for the existing writer before moving the file")

        edit(pending, suffix: "失败时必须保留的草稿。")
        await delayed.failOneWrite()
        let failedURL = pending.url
        do {
            try await pending.rename(to: "不应出现的名称")
            throw CheckFailure(description: "Save failure must prevent rename")
        } catch let error as CheckFailure { throw error } catch {}
        try expect(
            pending.url == failedURL && pending.hasUnsavedChanges
                && !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("不应出现的名称.md").path),
            "Save failure keeps the old file and draft")
    }
}
