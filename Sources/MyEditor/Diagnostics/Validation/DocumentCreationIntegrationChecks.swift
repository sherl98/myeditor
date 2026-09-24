#if DEBUG
    import AppKit
    import ManuscriptCore

    @MainActor enum DocumentCreationIntegrationChecks {
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw FeatureIntegrationChecks.Failure(message: message) }
                checks.append(message)
            }
            func wait(_ message: String, _ condition: () -> Bool) async throws {
                for _ in 0..<200 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw FeatureIntegrationChecks.Failure(message: message)
            }
            application.newDocument()
            guard let session = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: "New document opens")
            }
            try await wait("New editor becomes ready") { session.editorReady }
            guard let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator
            else {
                throw FeatureIntegrationChecks.Failure(message: "New editor bridge exists")
            }
            try check(
                session.isUntitled && session.isEditing && session.source.isEmpty,
                "New document opens blank in editing mode")
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEdit('新文稿中文API与 emoji 👩🏽‍💻。')")
            try await wait("Draft input reaches native session") { session.hasUnsavedChanges }
            try await Task.sleep(for: .milliseconds(1000))
            try check(
                session.isUntitled && session.successfulSaveCount == 0,
                "Typing and idle never save an untitled document")
            application.toggleEditing(session)
            try await wait("Draft switches to reading without saving") {
                !session.isEditing && !session.isClosing
            }
            try check(
                session.isUntitled && session.hasUnsavedChanges,
                "Finishing editing retains the in-memory draft")
            application.toggleEditing(session)
            try await wait("Draft returns to editing") { session.isEditing }
            try check(
                await application.flushEditor(session), "First save flushes the actual editor")
            let destination = directory.appendingPathComponent("新文稿首次保存.md")
            let revision = session.documentRevision
            try await application.store.saveFirst(session, to: destination)
            application.updateWindow(for: session)
            try check(
                try String(contentsOf: destination, encoding: .utf8) == session.serializedSource(),
                "First save writes the complete Markdown source")
            let state =
                try await bridge.evaluateForValidation("return window.MyEditor.inspect()")
                as! [String: Any]
            try check(
                session.documentRevision == revision
                    && (state["mountCount"] as? NSNumber)?.intValue == 1,
                "First save preserves the same WebKit editor")
            await bridge.undo()
            try await wait("Undo crosses first save") { !session.source.contains("新文稿中文API") }
            await bridge.redo()
            try await wait("Redo crosses first save") { session.source.contains("新文稿中文API") }
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEdit('首次保存后的自动保存。')")
            try await wait("Autosave finishes") {
                !session.hasUnsavedChanges && session.successfulSaveCount > 1
            }
            try check(
                try String(contentsOf: destination, encoding: .utf8).contains("首次保存后的自动保存。"),
                "Subsequent edits autosave to the chosen destination")
            application.requestClose(session)
            try await wait("Saved document closes without a first-save prompt") { session.isClosed }
            let imageSource = "![本地图片](first-save-image.svg)"
            try
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><rect width=\"16\" height=\"16\" fill=\"green\"/></svg>"
                .write(
                    to: directory.appendingPathComponent("first-save-image.svg"), atomically: true,
                    encoding: .utf8)
            application.newDocument()
            guard let imageSession = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: "Image draft opens")
            }
            imageSession.receiveEditorSource(imageSource, sequence: 1, revision: 0)
            try await wait("Image draft becomes ready") { imageSession.editorReady }
            guard
                let imageBridge = application.editor(for: imageSession)
                    as? MarkdownWebEditor.Coordinator
            else {
                throw FeatureIntegrationChecks.Failure(message: "Image draft bridge exists")
            }
            try await application.store.saveFirst(
                imageSession, to: directory.appendingPathComponent("新文稿图片.md"))
            var imageLoaded = false
            for _ in 0..<100 {
                imageLoaded =
                    try await imageBridge.evaluateForValidation(
                        "return [...document.images].some(image => image.naturalWidth === 16 && image.src.includes('first-save-image.svg'))"
                    ) as? Bool == true
                if imageLoaded { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            try check(
                imageLoaded && imageSession.source == imageSource,
                "Relative images resolve against the first save directory without changing Markdown"
            )
            application.requestClose(imageSession)
            try await wait("Image document closes") { imageSession.isClosed }
            return checks
        }
    }
#endif
