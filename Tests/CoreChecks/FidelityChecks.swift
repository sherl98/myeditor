import Foundation
import ManuscriptCore

extension Checks {
    func fileFidelity() async throws {
        let spaced = try await session("trailing-lines", source: "# 标题\n\n正文。\n\n\n")
        defer { spaced.close() }
        replace(spaced, with: "# 标题\n\n正文改。\n\n\n")
        try expect(await spaced.save(.explicit), "Edited document with blank tail saves")
        try expect(
            try String(contentsOf: spaced.url!, encoding: .utf8) == "# 标题\n\n正文改。\n\n\n",
            "Trailing blank lines the editor preserved are written unchanged")
        replace(spaced, with: "# 标题\n\n正文改。")
        try expect(await spaced.save(.explicit), "Edited document without tail saves")
        try expect(
            try String(contentsOf: spaced.url!, encoding: .utf8) == "# 标题\n\n正文改。\n",
            "A file that ended with a newline keeps one")

        let copy = directory.appendingPathComponent("permissions-copy.md")
        _ = try await DiskFileAccess(coordinateAccess: false).writeCopy(copy, source: "新文件\n")
        let mask = umask(0)
        umask(mask)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions]
        try expect(
            (mode as? NSNumber)?.uint16Value == 0o666 & ~UInt16(mask),
            "New files follow the user's umask like other apps")

        let tracked = try await session("observation")
        defer { tracked.close() }
        try expect(!tracked.hasDraft, "An opened document has no draft")
        edit(tracked, suffix: "新增一句。\n")
        try expect(tracked.hasDraft && tracked.hasUnsavedChanges, "An edit creates a draft")
        edit(tracked, suffix: "再加一句。\n")
        try expect(tracked.hasDraft, "Further edits keep the draft flag without toggling it")
        try expect(await tracked.save(.explicit), "Draft saves")
        try expect(!tracked.hasDraft && !tracked.hasUnsavedChanges, "Saving clears the draft")
        tracked.notePendingEditorChanges()
        tracked.notePendingEditorChanges()
        try expect(tracked.editorHasPendingChanges, "Repeated pending input stays pending")
    }

    func markdownExtensions() async throws {
        try expect(
            ["a.md", "b.markdown", "c.MDOWN", "d.mkd", "e.mkdn"].allSatisfy {
                ManuscriptCodec.isMarkdownFile(URL(fileURLWithPath: "/tmp/\($0)"))
            } && !ManuscriptCodec.isMarkdownFile(URL(fileURLWithPath: "/tmp/f.txt")),
            "Common Markdown extensions are recognised in any case")
        let url = directory.appendingPathComponent("笔记.markdown")
        try "# 笔记\n".write(to: url, atomically: true, encoding: .utf8)
        let files = DiskFileAccess(coordinateAccess: false)
        let s = try DocumentSession(
            url: url, snapshot: try await files.read(url), files: files, watch: false)
        defer { s.close() }
        s.setEditorReady(true)
        try await s.rename(to: "新笔记")
        try expect(
            s.url?.lastPathComponent == "新笔记.markdown" && s.fileExtension == "markdown",
            "Rename keeps the document's own Markdown extension")
        try await s.rename(to: "改用短扩展名.md")
        try expect(
            s.url?.lastPathComponent == "改用短扩展名.md", "A typed Markdown extension is used as given")
        let draft = DocumentSession(untitledName: "未命名")
        try await draft.rename(to: "草稿.markdown")
        try expect(
            draft.suggestedName == "草稿" && draft.fileExtension == "md",
            "An untitled name drops the typed extension")
    }

    func legacyPreferences() throws {
        let name = "MyEditorChecks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw CheckFailure(description: "Test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(120, forKey: "reader.fontPercent")
        let legacy: [String: Any] = [
            "reader.fontPercent": 90, "reader.appearance": "dark", "NSWindow Frame": "x",
        ]
        let copied = LegacyPreferences.migrate(from: legacy, into: defaults)
        try expect(
            copied == 1 && defaults.string(forKey: "reader.appearance") == "dark"
                && defaults.integer(forKey: "reader.fontPercent") == 120
                && defaults.object(forKey: "NSWindow Frame") == nil,
            "Earlier reader settings are copied without replacing current ones")
        defaults.removeObject(forKey: "reader.appearance")
        try expect(
            LegacyPreferences.migrate(from: legacy, into: defaults) == 0
                && defaults.object(forKey: "reader.appearance") == nil,
            "Settings migrate only once")
    }

    func missingFileRecovery() async throws {
        let s = try await session("comes-back", watch: true)
        defer { s.close() }
        let url = s.url!
        let bytes = try Data(contentsOf: url)
        let reloads = s.externalReloadCount
        try FileManager.default.removeItem(at: url)
        try await waitUntil("Missing file is reported") { s.issue != nil }
        try bytes.write(to: url)
        try await waitUntil("Restored identical file clears the notice") { s.issue == nil }
        try expect(
            s.externalReloadCount == reloads && !s.hasUnsavedChanges,
            "Identical bytes do not reload the editor or mark changes")
        edit(s, suffix: "恢复后继续写。\n")
        try await waitUntil("Autosave resumes after the file returns") { !s.hasUnsavedChanges }
        try expect(
            try String(contentsOf: url, encoding: .utf8).hasSuffix("恢复后继续写。\n"),
            "Writes go to the restored file")
    }
}
