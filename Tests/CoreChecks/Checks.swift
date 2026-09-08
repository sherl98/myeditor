import Foundation
import ManuscriptCore

struct CheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor final class Checks {
    var count = 0
    let directory: URL
    let fixture = "# 示例\n\n## 第一章\n\n中文与 emoji 👩🏽‍💻。\n\n## 第二章\n\n末段。\n"
    private var sequences: [UUID: UInt64] = [:]
    init(directory: URL) { self.directory = directory }
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        count += 1
    }
    func waitUntil(_ message: String, condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() {
                count += 1
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CheckFailure(description: message)
    }
    func file(_ name: String, source: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name + ".md")
        try (source ?? fixture).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func session(_ name: String, source: String? = nil, watch: Bool = false) async throws
        -> DocumentSession
    {
        let url = try file(name, source: source)
        let files = DiskFileAccess(coordinateAccess: false)
        let session = try DocumentSession(
            url: url, snapshot: await files.read(url), files: files, watch: watch)
        session.setEditorReady(true)
        return session
    }
    func replace(_ session: DocumentSession, with text: String) {
        sequences[session.id, default: 0] += 1
        session.receiveEditorSource(
            text, sequence: sequences[session.id]!, revision: session.documentRevision)
    }
    func edit(_ session: DocumentSession, suffix: String) {
        replace(session, with: session.source + suffix)
    }

    func formatsAndModes() async throws {
        for (index, text) in [
            "", "没有任何标题。", "### 小标题\n\n- [x] 完成\n\n| A | B |\n| - | - |\n| 中 | 文 |",
            "---\ntitle: 测试\n---\n\n<script>example</script>",
        ].enumerated() {
            let session = try await session("format-\(index)", source: text)
            session.beginEditing()
            try expect(session.isEditing, "Any UTF-8 Markdown enters editing")
            try expect(await session.finishEditing(), "Unchanged mode toggle succeeds")
            try expect(
                try String(contentsOf: session.url, encoding: .utf8) == text
                    && session.successfulSaveCount == 0,
                "Read/edit toggle never normalizes an untouched file")
            replace(session, with: "")
            try expect(await session.save(.explicit), "Removing all content is valid")
            session.close()
        }
        let original = "\u{FEFF}" + fixture.replacingOccurrences(of: "\n", with: "\r\n")
        let session = try await session("bom-crlf", source: original)
        defer { session.close() }
        try expect(
            try ManuscriptCodec.sourceFromUTF8(Data(original.utf8)) == original,
            "UTF-8 BOM survives decoding")
        replace(session, with: "# 新标题\n\n全文替换。\n\n###### 新小节")
        try expect(
            await session.save(.explicit), "Arbitrary structure can replace the whole document")
        let data = try Data(contentsOf: session.url)
        let result = String(decoding: data, as: UTF8.self)
        try expect(data.starts(with: [0xef, 0xbb, 0xbf]), "BOM survives WYSIWYG save")
        try expect(
            !result.replacingOccurrences(of: "\r\n", with: "").contains("\n")
                && result.hasSuffix("\r\n"), "CRLF and EOF convention survive save")
        let generation = session.generation
        session.receiveEditorSource(
            "# 新标题\n\n全文替换。\n\n###### 新小节", sequence: 1, revision: session.documentRevision)
        try expect(
            session.generation == generation && !session.hasUnsavedChanges,
            "Replayed flush does not dirty normalized saved text")
        let headings = [
            DocumentHeading(id: "book", title: "书名", level: 1, offset: 0),
            DocumentHeading(id: "a", title: "重复", level: 2, offset: 10),
            DocumentHeading(id: "sub", title: "小节", level: 4, offset: 20),
            DocumentHeading(id: "b", title: "重复", level: 2, offset: 30),
        ]
        try expect(
            ManuscriptCodec.primaryHeadings(headings).map(\.id) == ["a", "b"],
            "Rail uses main chapters below a single document title")
        try expect(ManuscriptCodec.primaryHeadings([]).isEmpty, "No headings need no rail")
        try expect(
            ManuscriptCodec.primaryHeadings([headings[0]]).count == 1,
            "Single heading remains navigable")
        try expect(
            ManuscriptCodec.characterCount("中文 👩🏽‍💻") == 3, "Character count respects composed Unicode"
        )
    }

    func autosaveAndComposition() async throws {
        let a = try await session("autosave", watch: true)
        let b = try await session("second-document")
        defer {
            a.close()
            b.close()
        }
        a.updateHistory(canUndo: true, canRedo: false)
        a.beginEditing()
        edit(a, suffix: "跨章节编辑。\n")
        try await waitUntil("Debounced autosave completed") { !a.hasUnsavedChanges }
        try expect(a.canUndo && !b.canUndo, "Save preserves independent editor history state")
        let original = a.source
        a.setComposing(true)
        replace(a, with: original + "zhongwen")
        try await Task.sleep(for: .milliseconds(850))
        try expect(!(await a.save(.explicit)), "Composition blocks explicit and idle writes")
        try expect(
            !(try String(contentsOf: a.url, encoding: .utf8)).contains("zhongwen"),
            "Candidate text never reaches disk")
        replace(a, with: original + "中文")
        a.setComposing(false)
        try expect(await a.save(.composition), "Confirmed input saves")
        try expect(
            !(try String(contentsOf: a.url, encoding: .utf8)).contains("zhongwen"),
            "Confirmed text replaces candidate")
        try expect(await a.finishEditing() && a.canUndo, "Returning to read-only retains history")
        try await Task.sleep(for: .milliseconds(350))
        try expect(a.externalReloadCount == 0, "Own writes do not reset the editor")
    }

    func conflictsAndFailures() async throws {
        let s = try await session("conflicts")
        defer { s.close() }
        let external = "普通正文，没有标题。\n"
        try external.write(to: s.url, atomically: true, encoding: .utf8)
        await s.checkExternalChanges()
        try expect(
            s.source == external && s.documentRevision == 1,
            "Clean external content reloads without a heading requirement")
        s.receiveEditorSource("旧页面晚到消息", sequence: 99, revision: 0)
        try expect(
            s.source == external && !s.hasUnsavedChanges,
            "Old document revision cannot overwrite an external reload")
        edit(s, suffix: "本地草稿")
        let newer = external + "外部修改。\n"
        try newer.write(to: s.url, atomically: true, encoding: .utf8)
        await s.checkExternalChanges()
        try expect(s.hasConflict && s.source.contains("本地草稿"), "External conflict preserves draft")
        try expect(!(await s.save(.explicit)), "Conflict blocks overwrite")
        try expect(
            try String(contentsOf: s.url, encoding: .utf8) == newer, "External file stays intact")
        s.keepDraft()
        await s.checkExternalChanges()
        try expect(s.keptConflictingDraft, "Keep-draft choice survives unchanged watcher events")
        let copy = directory.appendingPathComponent("conflict-copy.md")
        _ = try await s.writeCopy(to: copy)
        try expect(
            try String(contentsOf: copy, encoding: .utf8).contains("本地草稿"),
            "Save-copy captures complete draft")
        try expect(await s.loadExternalVersion(), "Explicit external acceptance succeeds")
        try expect(
            !s.hasConflict && !s.canUndo && !s.hasUnsavedChanges,
            "External acceptance resets history and draft")
        edit(s, suffix: "权限测试")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: s.url.path)
        try expect(
            !(await s.save(.explicit)) && s.hasUnsavedChanges, "Unwritable file retains draft")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: s.url.path)
        try expect(await s.save(.explicit), "Write can be retried")
        try expect(
            (try FileManager.default.attributesOfItem(atPath: s.url.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o640, "Atomic replacement preserves permissions")
        edit(s, suffix: "删除测试")
        try FileManager.default.removeItem(at: s.url)
        try expect(
            !(await s.save(.close)) && !FileManager.default.fileExists(atPath: s.url.path),
            "Missing file is not recreated by autosave")
    }

    func watcherAndResources() async throws {
        var current: DocumentSession? = try await session("watcher", watch: true)
        weak var released = current
        let url = current!.url
        try "外部原子替换。\n".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil("Watcher follows external atomic replacement") {
            current?.source == "外部原子替换。\n"
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("继续追加。\n".utf8))
        try handle.close()
        try await waitUntil("Watcher reattaches after replacement") {
            current?.source.contains("继续追加") == true
        }
        try FileManager.default.removeItem(at: url)
        try await waitUntil("Watcher reports deletion of the selected file") {
            current?.issue != nil
        }
        // Leave a gap long enough for reattachment to fail before recreating it.
        try await Task.sleep(for: .milliseconds(650))
        try "删除后重新创建。\n".write(to: url, atomically: true, encoding: .utf8)
        try await waitUntil("Watcher finds a recreated file without watching its parent") {
            current?.source == "删除后重新创建。\n"
        }
        current?.close()
        current = nil
        try await waitUntil("Closed document releases resources") { released == nil }
    }

    func bridgeSynchronization() async throws {
        let s = try await session("bridge-sync")
        defer { s.close() }
        let original = s.source
        let external = "外部更新。\n"
        try external.write(to: s.url, atomically: true, encoding: .utf8)
        var flushes = 0
        s.prepareForExternalReload = { [weak s] in
            guard let s else { return false }
            flushes += 1
            self.replace(s, with: original + "尚在桥接中的输入。")
            return true
        }
        await s.checkExternalChanges()
        try expect(flushes == 1, "External reload first drains pending browser input")
        try expect(
            s.hasConflict && s.source.contains("尚在桥接中的输入"),
            "Late browser input becomes a preserved conflict")
        try expect(
            try String(contentsOf: s.url, encoding: .utf8) == external,
            "Browser synchronization never overwrites the external version")
        let failed = try await session("bridge-unavailable")
        defer { failed.close() }
        failed.prepareForExternalReload = { false }
        try external.write(to: failed.url, atomically: true, encoding: .utf8)
        await failed.checkExternalChanges()
        try expect(
            failed.documentRevision == 0 && failed.source == fixture,
            "Failed browser flush postpones external replacement")
    }
}

@main struct NovelReaderChecks {
    @MainActor static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MyEditorChecks-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let checks = Checks(directory: directory)
            if CommandLine.arguments.contains("--rename") {
                try await checks.renaming()
                try await checks.editorRecovery()
                print("PASS: \(checks.count) rename checks.")
                return
            }
            if CommandLine.arguments.contains("--source-sync") {
                try await checks.bridgeSynchronization()
                print("PASS: \(checks.count) bridge synchronization checks.")
                return
            }
            try await checks.formatsAndModes()
            try await checks.autosaveAndComposition()
            try await checks.conflictsAndFailures()
            try await checks.saveOrdering()
            try await checks.watcherAndResources()
            try await checks.bridgeSynchronization()
            try await checks.renaming()
            try await checks.editorRecovery()
            print("PASS: \(checks.count) document checks. All writes used disposable fixtures.")
        } catch {
            print("FAIL: \(error)")
            Foundation.exit(1)
        }
    }
}
