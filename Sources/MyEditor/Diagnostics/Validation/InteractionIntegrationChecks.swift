#if DEBUG
    import AppKit
    import ManuscriptCore
    import WebKit

    /// Native interactions: Edit menu routing, toolbar widths, opening files and
    /// network images.
    @MainActor enum InteractionIntegrationChecks {
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw FeatureIntegrationChecks.Failure(message: message) }
                checks.append(message)
            }
            func wait(_ message: String, until condition: () -> Bool) async throws {
                for _ in 0..<250 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw FeatureIntegrationChecks.Failure(message: message)
            }
            func searchField(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.lazy.compactMap { searchField($0) }.first
            }
            let url = directory.appendingPathComponent("快捷键验收.md")
            try "# 快捷键\n\n正文段落。\n".write(to: url, atomically: true, encoding: .utf8)
            application.open([url])
            await application.waitForValidationOpen()
            guard let session = application.activeSession,
                let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                let window = application.validationWindow(for: session),
                let host = window.toolbar?.items.first(where: {
                    $0.itemIdentifier.rawValue == "reader.search"
                })?.view,
                let field = searchField(host)
            else { throw FeatureIntegrationChecks.Failure(message: "Interaction fixture opens") }
            window.makeKeyAndOrderFront(nil)
            try await wait("Interaction editor ready") { session.editorReady }
            application.toggleEditing(session)
            try await wait("Interaction document editable") { session.isEditing }
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEditBlock(1, '已编辑')")
            try await wait("Document undo becomes available") { application.canUndo }
            let edited = session.source

            // Synthetic key events do not follow the hardware ⌘Z path, so the
            // menu actions are invoked directly with each focus. Earlier groups may
            // have left another app in front.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            application.searching.focus()
            try await wait("Search field focused") { field.currentEditor() != nil }
            guard let editor = field.currentEditor() as? NSTextView else {
                throw FeatureIntegrationChecks.Failure(message: "Field editor exists")
            }
            editor.insertText("abc", replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
            try await wait("Query typed") { field.stringValue == "abc" }
            // Focus is refreshed once per event loop pass, as after a real key or click.
            NSApp.updateWindows()
            try await wait("Native text focus is tracked") { application.nativeTextFocused }
            application.performUndo()
            try await Task.sleep(for: .milliseconds(200))
            _ = await application.flushEditor(session)
            try check(
                field.stringValue != "abc", "Undo with the search field focused edits the field")
            try check(
                session.source == edited, "Undo in the search field leaves the document alone")

            application.searching.end(session, returnToDocument: true)
            window.makeFirstResponder(bridge.webView)
            NSApp.updateWindows()
            try await wait("Document focus is tracked") { !application.nativeTextFocused }
            application.performUndo()
            try await wait("Document undo applies") { !session.source.contains("已编辑") }
            try check(true, "Undo with the document focused undoes the document edit")
            // Narrow windows keep the edit controls in the toolbar itself; wider
            // windows give the free width to the search field.
            let prompt = ((field.placeholderString ?? "") as NSString).size(
                withAttributes: [.font: field.font ?? .systemFont(ofSize: 12)]
            ).width
            for width in [480.0, 640, 960] {
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 700)),
                    display: true)
                try await Task.sleep(for: .milliseconds(300))
                let items = window.toolbar?.visibleItems ?? []
                let visible = items.map(\.itemIdentifier.rawValue)
                try check(
                    visible.contains("reader.controls") && visible.contains("reader.search"),
                    "At \(Int(width)) pt the edit controls and search stay visible")
                let search = host.convert(host.bounds, to: nil)
                let next =
                    items.compactMap(\.view).filter { $0 !== host }
                    .map { $0.convert($0.bounds, to: nil).minX }
                    .filter { $0 >= search.maxX }.min() ?? search.maxX
                let text =
                    (field.cell as? NSSearchFieldCell)?.searchTextRect(forBounds: field.bounds)
                    .width ?? 0
                try check(
                    next - search.maxX <= 32,
                    "At \(Int(width)) pt the search field fills the free width (gap \(Int(next - search.maxX)) pt)"
                )
                try check(
                    text >= prompt + 4,
                    "At \(Int(width)) pt the placeholder fits (\(Int(text)) of \(Int(prompt)) pt)"
                )
            }
            await application.save(session, reason: .explicit)
            application.requestClose(session)
            try await wait("Interaction fixture closes") { session.isClosed }

            // Other Markdown extensions open; an error alert does not hold later opens.
            let other = directory.appendingPathComponent("扩展名验收.markdown")
            try "# 另一种扩展名\n".write(to: other, atomically: true, encoding: .utf8)
            let rejected = directory.appendingPathComponent("不是文档.txt")
            try "text".write(to: rejected, atomically: true, encoding: .utf8)
            application.open([rejected])
            await application.waitForValidationOpen()
            try await Task.sleep(for: .milliseconds(300))
            let alertWindow = NSApp.windows.first { $0.attachedSheet != nil }
            application.open([other])
            await application.waitForValidationOpen()
            guard let opened = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: ".markdown document opens")
            }
            try check(
                opened.url?.pathExtension == "markdown" && alertWindow != nil,
                "A .markdown file opens while the previous error is still shown")
            if let alertWindow, let sheet = alertWindow.attachedSheet {
                alertWindow.endSheet(sheet)
            }
            try await wait(".markdown editor ready") { opened.editorReady }
            application.requestClose(opened)
            try await wait(".markdown document closes") { opened.isClosed }

            // Network images are not requested until this document allows them.
            let remote = "https://example.com/myeditor-remote.png"
            let imageURL = directory.appendingPathComponent("网络图片验收.md")
            let imageSource = "# 图片\n\n![网络图片](\(remote))\n"
            try imageSource.write(to: imageURL, atomically: true, encoding: .utf8)
            application.preferences.loadRemoteImages = false
            application.open([imageURL])
            await application.waitForValidationOpen()
            guard let pictured = application.activeSession,
                let pictureBridge = application.editor(for: pictured)
                    as? MarkdownWebEditor.Coordinator
            else { throw FeatureIntegrationChecks.Failure(message: "Image document opens") }
            try await wait("Blocked image is reported") {
                application.blockedRemoteImages[pictured.id] == 1
            }
            func renderedImage() async throws -> String {
                try await pictureBridge.evaluateForValidation(
                    "return document.querySelector('.document-content img')?.getAttribute('src') || ''"
                ) as? String ?? ""
            }
            // Our placeholder is an encoded "<svg"; a requested image either shows
            // or falls back to MDXEditor's broken-image icon (example.com has none).
            let ownPlaceholder = "data:image/svg+xml;charset=utf-8,%3Csvg"
            var placeholder = false
            for _ in 0..<100 where !placeholder {
                placeholder = try await renderedImage().hasPrefix(ownPlaceholder)
                if !placeholder { try await Task.sleep(for: .milliseconds(50)) }
            }
            try check(placeholder, "A network image shows a placeholder instead of loading")
            application.allowRemoteImages(pictured)
            var requested = false
            for _ in 0..<100 where !requested {
                let current = try await renderedImage()
                requested = !current.isEmpty && !current.hasPrefix(ownPlaceholder)
                if !requested { try await Task.sleep(for: .milliseconds(50)) }
            }
            try check(
                requested && application.blockedRemoteImages[pictured.id] == nil
                    && pictured.source == imageSource && !pictured.hasUnsavedChanges,
                "Allowing images requests them in place without touching the document")
            application.requestClose(pictured)
            try await wait("Image document closes") { pictured.isClosed }
            return checks
        }
    }
#endif
