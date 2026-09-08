#if DEBUG
    import Foundation
    import AppKit
    import ManuscriptCore

    /// One focused pass through the actual WebKit, toolbar and coordinated writer.
    @MainActor enum EditorIntegrationChecks {
        private struct Failure: Error { let message: String }
        static func run(application: ApplicationController) async {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "MyEditor local integration validation")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            guard
                let path = Bundle.main.object(forInfoDictionaryKey: "NRDiagnosticsDirectory")
                    as? String
            else { return }
            let directory = URL(fileURLWithPath: path)
            let url = directory.appendingPathComponent("全文编辑验收-\(UUID().uuidString).md")
            var completed: [String] = []
            var failure: String?
            let previousData = try? Data(
                contentsOf: directory.appendingPathComponent("editor-checks.json"))
            let previous = previousData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let resumeAtHistory = previous?["failure"] as? String == "Editor undo works after save"
            if resumeAtHistory { completed = previous?["checks"] as? [String] ?? [] }
            let originalFont = application.preferences.fontPercent
            let originalTheme = application.preferences.appearance
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw Failure(message: name) }
                completed.append(name)
            }
            func wait(_ name: String, until condition: () -> Bool) async throws {
                for _ in 0..<400 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw Failure(message: name)
            }
            func open(_ url: URL) async throws -> DocumentSession {
                application.open([url])
                await application.waitForValidationOpen()
                guard let session = application.store.sessions.first(where: { $0.url == url })
                else { throw Failure(message: "Document opens") }
                try await wait("Local editor becomes ready") { session.editorReady }
                return session
            }
            do {
                let original: String
                if let input = Bundle.main.object(
                    forInfoDictionaryKey: "NRValidationManuscriptResource") as? String,
                    let inputURL = Bundle.main.resourceURL?.appendingPathComponent(input),
                    FileManager.default.fileExists(atPath: inputURL.path)
                {
                    original = try String(contentsOf: inputURL, encoding: .utf8)
                } else {
                    original = "# 文档\n\n## 第一章\n\n中文正文。\n\n## 第二章\n\n第二段。\n"
                }
                try original.write(to: url, atomically: true, encoding: .utf8)
                let session = try await open(url)
                guard
                    let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                    let controller = application.validationController(for: session),
                    let window = controller.window
                else { throw Failure(message: "Native controller and WebKit bridge exist") }
                func checkAppearance() async throws {
                    var matched = false
                    for _ in 0..<100 {
                        let dark =
                            window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                            == .darkAqua
                        let background = dark ? "rgb(30, 30, 30)" : "rgb(255, 255, 255)"
                        let actual =
                            try await bridge.evaluateForValidation(
                                "return getComputedStyle(document.body).backgroundColor") as? String
                        matched = actual == background
                        if matched { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try check(matched, "Document background matches native window appearance")
                    // Let delayed WebKit media events run, then verify the result stays consistent.
                    try await Task.sleep(for: .milliseconds(150))
                    let nativeDark =
                        window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let webDark =
                        try await bridge.evaluateForValidation(
                            "return document.documentElement.classList.contains('dark-theme')")
                        as? Bool
                    try check(
                        webDark == nativeDark, "Delayed WebKit events preserve native appearance")
                }
                var state =
                    try await bridge.evaluateForValidation("return window.MyEditor.inspect()")
                    as! [String: Any]
                let originalFrame = window.frame
                if !resumeAtHistory {
                    for theme in [ReaderAppearance.light, .dark, .system, .light, .system] {
                        application.setAppearance(theme)
                        try await wait("Theme preference changes") {
                            application.preferences.appearance == theme
                        }
                        try await checkAppearance()
                    }
                    // Simulate native appearance changes without modifying the user's OS setting.
                    for nativeName in [NSAppearance.Name.darkAqua, .aqua] {
                        NSApp.appearance = NSAppearance(named: nativeName)
                        try await wait("Native appearance observer updates the system theme") {
                            application.preferences.resolvedDarkAppearance
                                == (nativeName == .darkAqua)
                        }
                        try await checkAppearance()
                    }
                    application.preferences.applyAppearance()
                    try await checkAppearance()
                    try check(
                        state["readOnly"] as? Bool == true && state["fallback"] as? Bool == false,
                        "Large document opens as rendered read-only Markdown")
                    try check(
                        try String(contentsOf: url, encoding: .utf8) == original
                            && !session.hasUnsavedChanges, "Opening never rewrites Markdown")
                    for width in [CGFloat(760), 1100, 860, 1280] {
                        window.setFrame(
                            NSRect(
                                origin: window.frame.origin,
                                size: NSSize(width: width, height: originalFrame.height)),
                            display: true)
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    state =
                        try await bridge.evaluateForValidation("return window.MyEditor.inspect()")
                        as! [String: Any]
                    try check(
                        (state["mountCount"] as? NSNumber)?.intValue == 1
                            && session.generation == 0,
                        "Resizing keeps one editor instance and does not mutate source")
                    guard let toolbar = window.toolbar,
                        let chapters = toolbar.items.first(where: {
                            $0.itemIdentifier.rawValue == "reader.chapters"
                        })?.menuFormRepresentation?.submenu,
                        let controls = toolbar.items.first(where: {
                            $0.itemIdentifier.rawValue == "reader.controls"
                        })?.menuFormRepresentation?.submenu
                    else { throw Failure(message: "Toolbar items provide overflow menus") }
                    controller.menuNeedsUpdate(chapters)
                    controller.menuNeedsUpdate(controls)
                    try check(
                        chapters.items.count == session.outline.count,
                        "Overflow directory contains every heading")
                    if session.outline.count > 1 {
                        chapters.performActionForItem(at: 1)
                        try await wait("Overflow directory action navigates") {
                            session.activeHeadingID == session.outline[1].id
                        }
                    }
                    application.preferences.fontPercent = 110
                    controls.performActionForItem(at: 1)
                    try await wait("Overflow theme action completes") {
                        application.preferences.appearance == .light
                    }
                    try check(
                        application.preferences.fontPercent == 110
                            && application.preferences.appearance == .light,
                        "Footer font preference and overflow theme action work")
                    controls.performActionForItem(at: 4)
                    try await wait("Overflow edit action enables editing") { session.isEditing }
                } else {
                    session.beginEditing()
                }
                _ = try await bridge.evaluateForValidation(
                    "return await window.MyEditor.validationEdit('全文原位编辑验收 中文 👩🏽‍💻')")
                try await wait("Edit reaches native session") {
                    session.source.contains("全文原位编辑验收")
                }
                let saved = await application.save(session, reason: .explicit)
                if !resumeAtHistory {
                    try check(saved, "Full document saves through the coordinated writer")
                    try check(
                        try String(contentsOf: url, encoding: .utf8).contains("全文原位编辑验收 中文 👩🏽‍💻"),
                        "Unicode editing reaches disk intact")
                } else if !saved {
                    throw Failure(message: "History fixture saves")
                }
                await bridge.undo()
                try check(!session.source.contains("全文原位编辑验收"), "Editor undo works after save")
                await bridge.redo()
                try check(
                    session.source.contains("全文原位编辑验收"), "Editor redo shares native menu history")
                application.toggleEditing(session)
                try await wait("Read-only transition completes") {
                    !session.isEditing && !session.isClosing
                }
                state =
                    try await bridge.evaluateForValidation("return window.MyEditor.inspect()")
                    as! [String: Any]
                try check(
                    state["readOnly"] as? Bool == true
                        && (state["mountCount"] as? NSNumber)?.intValue == 1,
                    "Read-only toggle preserves the editor instance")
                window.setFrame(originalFrame, display: true)

                let mixedURL = directory.appendingPathComponent(
                    "Markdown-Structures-\(UUID().uuidString).md")
                let fence = String(repeating: "\u{0060}", count: 3)
                let mixed =
                    "---\ntitle: 元数据\n---\n\n标题\n====\n\n- [x] 任务\n\n| A | B |\n| - | - |\n| 中 | 文 |\n\n> 引用\n\n\(fence)md\n# 不属于目录\n\(fence)\n\n<script>window.__documentScriptExecuted = true</script>\n\n无标题正文。\n"
                try mixed.write(to: mixedURL, atomically: true, encoding: .utf8)
                let second = try await open(mixedURL)
                guard
                    let secondBridge = application.editor(for: second)
                        as? MarkdownWebEditor.Coordinator
                else { throw Failure(message: "Second editor exists") }
                let secondState =
                    try await secondBridge.evaluateForValidation(
                        "return { ...window.MyEditor.inspect(), table: !!document.querySelector('.document-content table'), executed: window.__documentScriptExecuted === true }"
                    ) as! [String: Any]
                try check(
                    secondState["fallback"] as? Bool == false
                        && secondState["table"] as? Bool == true,
                    "GFM and front matter render in the rich editor")
                try check(
                    second.outline.count == 1 && secondState["executed"] as? Bool == false,
                    "Code headings are ignored and document scripts never run")
                try check(
                    !second.canUndo && session.canUndo, "Tabs have independent undo histories")
                second.beginEditing()
                _ = try await secondBridge.evaluateForValidation(
                    "return await window.MyEditor.validationEdit('保留特殊语法')")
                try check(
                    await application.save(second, reason: .explicit),
                    "Mixed Markdown saves after an ordinary edit")
                let mixedSaved = try String(contentsOf: mixedURL, encoding: .utf8)
                try check(
                    mixedSaved.contains("title: 元数据")
                        && mixedSaved.contains(
                            "<script>window.__documentScriptExecuted = true</script>"),
                    "Metadata and raw HTML survive serialization")
                application.requestClose(second)
                try await wait("Second test document closes") { second.isClosed }
                application.requestClose(session)
                try await wait("Large test document closes") { session.isClosed }
                let reopened = try await open(url)
                try check(
                    reopened.source.contains("全文原位编辑验收") && !reopened.canUndo,
                    "Reopen restores complete content with a fresh history")
                application.requestClose(reopened)
            } catch let error as Failure { failure = error.message } catch {
                failure = error.localizedDescription
            }
            application.preferences.fontPercent = originalFont
            application.preferences.appearance = originalTheme
            let result: [String: Any] = [
                "passed": failure == nil, "checks": completed, "failure": failure ?? "",
                "scope":
                    "Actual WKWebView, native overflow actions, Unicode edits, undo/redo and file reopen; composition save guards covered by core checks",
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            {
                try? data.write(to: directory.appendingPathComponent("editor-checks.json"))
            }
        }
    }
#endif
