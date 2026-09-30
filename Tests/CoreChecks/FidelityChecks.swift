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
