#if DEBUG
    import AppKit
    import Foundation
    import ManuscriptCore
    import WebKit

    @MainActor enum SearchIntegrationChecks {
        struct Failure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func expect(_ condition: Bool, _ message: String) throws {
                guard condition else { throw Failure(message: message) }
                checks.append(message)
            }
            func wait(_ message: String, _ condition: () -> Bool) async throws {
                for _ in 0..<250 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw Failure(message: message)
            }
            // Fits in the window; all search presentation types have visible matches.
            let source =
                "# 小猫\n\n小**猫** 和 小猫\n\n| A | B |\n| - | - |\n| 小猫 | 内容 |\n\n```js\n小猫\n```\n\n<div>小猫</div>\n"
            let url = directory.appendingPathComponent("search-clear.md")
            try source.write(to: url, atomically: true, encoding: .utf8)
            application.open([url])
            await application.waitForValidationOpen()
            guard let session = application.activeSession else {
                throw Failure(message: "Search fixture opens")
            }
            try await wait("Search fixture ready") { session.editorReady }
            guard let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                let webView = bridge.webView,
                let window = application.validationWindow(for: session)
            else { throw Failure(message: "Native editor exists") }
            func searchField(_ view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                return view.subviews.lazy.compactMap { searchField($0) }.first
            }
            guard
                let host = window.toolbar?.items.first(where: {
                    $0.itemIdentifier.rawValue == "reader.search"
                })?.view,
                let field = searchField(host)
            else { throw Failure(message: "Native NSSearchField exists") }
            let originalSource = session.source
            for showsSource in [true, false] {
                session.showsSource = showsSource
                var switched = false
                for _ in 0..<100 {
                    let visible =
                        try await bridge.evaluateForValidation(
                            "return !!document.querySelector('[data-source-key=source-preview]')"
                        ) as? Bool
                    if visible == showsSource {
                        switched = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
                try expect(switched, "Display switches to \(showsSource ? "source" : "rendered")")
                if showsSource {
                    let styled =
                        try await bridge.evaluateForValidation(
                            """
                            const source = document.querySelector('.source-document');
                            const editor = source?.querySelector('.cm-editor');
                            const heading = source?.querySelector('.md-source-heading');
                            return !!source?.querySelector('.cm-lineNumbers .cm-gutterElement')
                                && !!heading && getComputedStyle(heading).fontWeight === '700'
                                && getComputedStyle(editor).borderTopWidth === '0px'
                                && getComputedStyle(editor).backgroundColor === 'rgba(0, 0, 0, 0)'
                            && [...source.querySelectorAll('.cm-line')].every(line =>
                                Math.abs(line.getBoundingClientRect().height - parseFloat(getComputedStyle(line).lineHeight)) < 1);
                            """
                        ) as? Bool
                    try expect(
                        styled == true,
                        "Source shows line numbers and Markdown styling without a card")
                    let image = try await webView.takeSnapshot(configuration: nil)
                    if let tiff = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: tiff),
                        let png = bitmap.representation(using: .png, properties: [:])
                    {
                        try png.write(to: URL(fileURLWithPath: "/tmp/myeditor-markdown-source.png"))
                    }
                }
                let inspected =
                    try await bridge.evaluateForValidation(
                        "return { source: window.MyEditor.inspect().source, sequence: window.MyEditor.inspect().sequence, mounts: window.MyEditor.inspect().mountCount }"
                    ) as! [String: Any]
                try expect(
                    inspected["source"] as? String == originalSource
                        && inspected["sequence"] as? Int == 0
                        && inspected["mounts"] as? Int == 1,
                    "Display switching preserves source and editor history")
            }
            let state = application.searchState(for: session)
            application.focusSearch()
            try await wait("Search field receives focus") { field.currentEditor() != nil }
            try await Task.sleep(for: .milliseconds(250))
            func snapshot(_ name: String) async throws -> Data {
                let image = try await webView.takeSnapshot(configuration: nil)
                guard let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                else { throw Failure(message: "Snapshot encodes") }
                try png.write(to: directory.appendingPathComponent(name + ".png"))
                return png
            }
            // Snapshot equality proves painted pixels, not only query/count state.
            for method in ["backspace", "select-delete", "cancel", "escape"] {
                window.makeFirstResponder(field)
                let baseline = try await snapshot("search-\(method)-baseline")
                guard let editor = field.currentEditor() as? NSTextView else {
                    throw Failure(message: "Field editor exists")
                }
                editor.insertText(
                    "小猫",
                    replacementRange: NSRange(
                        location: 0, length: (editor.string as NSString).length))
                try await wait("Query reaches native state") {
                    state.query == "小猫" && !state.isSearching && state.count > 0
                }
                try await Task.sleep(for: .milliseconds(180))
                let highlighted = try await snapshot("search-\(method)-highlighted")
                try expect(highlighted != baseline, "\(method): matched text visibly highlights")
                let before =
                    try await bridge.evaluateForValidation(
                        "return { source: window.MyEditor.inspect().source, sequence: window.MyEditor.inspect().sequence, y: window.scrollY, mounts: window.MyEditor.inspect().mountCount }"
                    ) as! [String: Any]
                switch method {
                case "backspace":
                    editor.setSelectedRange(
                        NSRange(location: (editor.string as NSString).length, length: 0))
                    editor.deleteBackward(nil)
                    editor.deleteBackward(nil)
                case "select-delete":
                    editor.selectAll(nil)
                    editor.deleteBackward(nil)
                case "cancel":
                    guard let cell = field.cell as? NSSearchFieldCell,
                        let button = cell.cancelButtonCell
                    else { throw Failure(message: "Native cancel button exists") }
                    button.performClick(field)
                default:
                    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                }
                try await wait("Clear acknowledged") {
                    state.query.isEmpty && state.pendingClearID == nil
                }
                try await Task.sleep(for: .milliseconds(180))
                let cleared = try await snapshot("search-\(method)-cleared")
                let after =
                    try await bridge.evaluateForValidation(
                        "return { source: window.MyEditor.inspect().source, sequence: window.MyEditor.inspect().sequence, y: window.scrollY, mounts: window.MyEditor.inspect().mountCount, highlights: CSS.highlights.size, marks: document.querySelectorAll('.source-search-match,.source-search-current').length }"
                    ) as! [String: Any]
                try expect(
                    after["highlights"] as? Int == 0 && after["marks"] as? Int == 0,
                    "\(method): all presentation registries clear")
                try expect(
                    cleared == baseline,
                    "\(method): pixels return to pre-search baseline without extra repaint")
                try expect(
                    after["source"] as? String == before["source"] as? String
                        && after["sequence"] as? Int == before["sequence"] as? Int
                        && after["y"] as? Double == before["y"] as? Double
                        && after["mounts"] as? Int == before["mounts"] as? Int,
                    "\(method): clear preserves source, scroll and editor instance")
                try expect(
                    method == "escape"
                        ? field.currentEditor() == nil : field.currentEditor() != nil,
                    "\(method): clear follows native focus policy")
            }
            // Pending search and reveal callbacks must never resurrect an old query.
            for query in ["小", "", "猫", "", "小猫"] {
                state.query = query
                application.search(session)
            }
            try await wait("Latest search wins") {
                state.query == "小猫" && !state.isSearching && state.count > 0
            }
            application.endSearch(session)
            try await wait("Final clear acknowledged") { state.pendingClearID == nil }
            try await Task.sleep(for: .milliseconds(400))
            let empty =
                try await bridge.evaluateForValidation(
                    "return window.MyEditor.inspect().search.count === 0 && CSS.highlights.size === 0"
                ) as? Bool == true
            try expect(empty, "Rapid queries stay cleared after deferred callbacks")
            try expect(
                try String(contentsOf: url, encoding: .utf8) == source && !session.hasUnsavedChanges
                    && !session.canUndo,
                "Search preserves fixture (diskEqual: \(try String(contentsOf: url, encoding: .utf8) == source), pending: \(session.editorHasPendingChanges), draft: \(session.draftSource != nil), undo: \(session.canUndo), generation: \(session.generation))"
            )
            application.requestClose(session)
            try await wait("Search fixture closes") { session.isClosed }
            return checks
        }
    }
#endif
