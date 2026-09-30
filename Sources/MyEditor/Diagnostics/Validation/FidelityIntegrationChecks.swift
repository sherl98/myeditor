#if DEBUG
    import AppKit
    import ManuscriptCore

    /// Editing one block writes that block only; untouched Markdown keeps its bytes.
    @MainActor enum FidelityIntegrationChecks {
        static let source = """
            Setext 标题
            ==========

            第一段有 _下划线斜体_ 和 __下划线粗体__。

            + 加号列表一
            + 加号列表二

            1) 括号编号
            2) 第二项

            * * *

                缩进代码块
                第二行

            | 左 | 中 | 右 |
            |:---|:---:|---:|
            | a | b | c |

            参考链接 [示例][ref]。

            [ref]: https://example.com "标题"

            <details><summary>HTML</summary>内容</details>


            最后一段。


            """

        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw FeatureIntegrationChecks.Failure(message: message) }
                checks.append(message)
            }
            func wait(_ message: String, until condition: () -> Bool) async throws {
                for _ in 0..<300 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw FeatureIntegrationChecks.Failure(message: message)
            }
            func changedLines(_ text: String) -> [String] {
                let before = source.components(separatedBy: "\n")
                let after = text.components(separatedBy: "\n")
                return (0..<max(before.count, after.count)).compactMap { index in
                    let old = index < before.count ? before[index] : nil
                    let new = index < after.count ? after[index] : nil
                    return old == new ? nil : new ?? "<removed>"
                }
            }
            let url = directory.appendingPathComponent("写法保真验收.md")
            try source.write(to: url, atomically: true, encoding: .utf8)
            application.open([url])
            await application.waitForValidationOpen()
            guard let session = application.activeSession,
                let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator
            else { throw FeatureIntegrationChecks.Failure(message: "Fidelity document opens") }
            try await wait("Fidelity editor ready") { session.editorReady }
            application.toggleEditing(session)
            try await wait("Fidelity document editable") { session.isEditing }
            let sync =
                try await bridge.evaluateForValidation("return window.MyEditor.inspect().sync")
                as? [String: Any] ?? [:]
            try check(
                sync["preserving"] as? Bool == true && sync["blocks"] as? Int == 11,
                "Every Markdown block maps to editor nodes")
            // Block index -> the only line expected to change.
            let edits: [(Int, String)] = [
                (0, "Setext 标题改"), (1, "第一段有 _下划线斜体_ 和 __下划线粗体__。改"), (2, "+ 加号列表二改"),
                (3, "2) 第二项改"), (7, "参考链接 [示例][ref]。改"), (10, "最后一段。改"),
            ]
            for (index, expected) in edits {
                _ = try await bridge.evaluateForValidation(
                    "return await window.MyEditor.validationEditBlock(\(index), '改')")
                _ = await application.flushEditor(session)
                try check(
                    changedLines(session.source) == [expected],
                    "Editing block \(index) rewrites only its own line")
                await bridge.undo()
                _ = await application.flushEditor(session)
                try check(
                    session.source == source && !session.hasDraft,
                    "Undo in block \(index) restores the original bytes")
            }
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEditBlock(10, '改')")
            try check(
                await application.save(session, reason: .explicit), "Edited document saves")
            try check(
                try String(contentsOf: url, encoding: .utf8)
                    == source.replacingOccurrences(of: "最后一段。", with: "最后一段。改"),
                "The saved file differs from the original by the edited words only")
            application.requestClose(session)
            try await wait("Fidelity document closes") { session.isClosed }
            return checks
        }
    }
#endif
