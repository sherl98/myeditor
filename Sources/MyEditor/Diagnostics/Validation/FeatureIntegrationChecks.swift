#if DEBUG
    import Foundation
    import AppKit
    import ManuscriptCore

    /// Targeted checks for this increment. Each group can be rerun independently.
    @MainActor enum FeatureIntegrationChecks {
        struct Failure: Error { let message: String }
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
            let phase =
                Bundle.main.object(forInfoDictionaryKey: "NRFeaturePhase") as? String ?? "all"
            let reportURL = directory.appendingPathComponent("feature-checks.json")
            var results: [String: Any] = [:]
            if phase != "all", let data = try? Data(contentsOf: reportURL),
                let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                results = previous["groups"] as? [String: Any] ?? [:]
            }
            let originalAccent = application.preferences.accentChoice
            let originalFont = application.preferences.fontPercent
            let originalContentFont = application.preferences.contentFont
            let originalCodeFont = application.preferences.codeFont
            let originalTheme = application.preferences.appearance
            let originalSize = application.preferences.windowSize
            var completed: [String] = []
            func check(_ value: Bool, _ message: String) throws {
                guard value else { throw Failure(message: message) }
                completed.append(message)
            }
            func wait(_ message: String, until condition: () -> Bool) async throws {
                for _ in 0..<500 {
                    if condition() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw Failure(message: message)
            }
            func open(_ source: String, name: String) async throws -> (
                DocumentSession, MarkdownWebEditor.Coordinator
            ) {
                let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).md")
                try source.write(to: url, atomically: true, encoding: .utf8)
                application.open([url])
                await application.waitForValidationOpen()
                guard let session = application.activeSession else {
                    throw Failure(message: "Document opens")
                }
                try await wait("Editor becomes ready") { session.editorReady }
                guard
                    let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator
                else { throw Failure(message: "Bridge exists") }
                return (session, bridge)
            }
            func query(_ text: String, session: DocumentSession) async throws -> DocumentSearchState
            {
                let state = application.searchState(for: session)
                state.query = text
                application.search(session)
                try await wait("Search completes: \(text)") { !state.isSearching }
                if let message = state.message { throw Failure(message: message) }
                return state
            }
            func replace(_ session: DocumentSession, with text: String, all: Bool = true)
                async throws
            {
                let state = application.searchState(for: session)
                state.replacement = text
                application.replace(session, all: all)
                try await wait("Replace completes") { !state.isReplacing }
                if state.message?.contains("请重新") == true { throw Failure(message: state.message!) }
            }
            func close(_ session: DocumentSession) async throws {
                application.requestClose(session)
                try await wait("Fixture closes") { session.isClosed }
            }
            for group in [
                "search-clear", "search", "mermaid", "large", "fonts", "empty", "recovery",
            ]
            where phase == "all" || phase.split(separator: ",").contains(Substring(group)) {
                completed = []
                do {
                    if group == "recovery" {
                        completed = try await RecoveryIntegrationChecks.run(
                            application: application, directory: directory)
                    } else if group == "search-clear" {
                        completed = try await SearchIntegrationChecks.run(
                            application: application, directory: directory)
                    } else if group == "search" {
                        let source =
                            "---\ntitle: 小猫\n---\n\n# 搜索小猫\n\n小**猫** 与 小猫 [小猫](https://hidden.example/小猫)\n\n| A | B |\n| - | - |\n| 小猫 | 内容 |\n\n```js\nconst pet = \"小猫\";\n```\n\n```mermaid\nflowchart LR\n A[\"小猫\"] --> B[\"文件\"]\n```\n\n<script>window.__documentScriptExecuted = true</script>\n"
                        let (session, bridge) = try await open(
                            source, name: "搜索与替换验收长文件名需要在末尾显示省略号")
                        let state = try await query("小猫", session: session)
                        try check(
                            state.count == 8,
                            "Search covers formatting, table, code and raw text, excludes hidden URL (\(state.count))"
                        )
                        try check(
                            !session.hasUnsavedChanges && !session.isEditing
                                && (try String(contentsOf: session.url, encoding: .utf8)) == source,
                            "Search does not rewrite a read-only document")
                        try await replace(session, with: "小猫")
                        try check(
                            !session.isEditing && !session.hasUnsavedChanges && !session.canUndo,
                            "Identical replacement is a true no-op")
                        try await replace(session, with: "小狗")
                        try check(
                            session.isEditing && session.source.contains("title: 小狗")
                                && session.source.contains("https://hidden.example/小猫"),
                            "Replace-all enables editing and preserves link destinations")
                        try check(
                            await application.save(session, reason: .explicit),
                            "Replacement saves through the coordinated writer")
                        let newMatches = try await query("小狗", session: session)
                        try check(
                            newMatches.count == 8,
                            "Every replacement is visible to the document search")
                        await bridge.undo()
                        let undone = try await query("小猫", session: session)
                        try check(
                            undone.count == 8 && !session.source.contains("小狗"),
                            "One undo restores all replacements after save")
                        await bridge.redo()
                        let redone = try await query("小狗", session: session)
                        try check(redone.count == 8, "Redo restores the document transaction")
                        let visible =
                            try await bridge.evaluateForValidation(
                                "return { table: document.querySelector('.document-content table')?.textContent.includes('小狗'), code: [...document.querySelectorAll('.source-editor .cm-content')].some(el => el.textContent.includes('const pet = \"小狗\"')), executed: window.__documentScriptExecuted === true }"
                            ) as! [String: Any]
                        try check(
                            visible["table"] as? Bool == true && visible["code"] as? Bool == true
                                && visible["executed"] as? Bool == false,
                            "Table and source views follow undo/redo; raw HTML stays inert")
                        try await replace(session, with: "", all: false)
                        let deleted = try await query("小狗", session: session)
                        try check(deleted.count == 7, "Single replacement supports deletion")
                        await bridge.undo()
                        let beforeStale = session.source
                        _ = try await bridge.evaluateForValidation(
                            "return await window.MyEditor.replace({ sessionID: 'stale', revision: -1, requestID: 999, query: '小狗', replacement: '错误', all: true })"
                        )
                        try check(
                            session.source == beforeStale,
                            "Stale document commands cannot overwrite content")
                        try await close(session)
                    } else if group == "mermaid" {
                        let source =
                            "# 流程图\n\n```mermaid\nflowchart LR\n A[\"中文起点\"] --> B[\"终点\"]\n```\n"
                        let (session, bridge) = try await open(source, name: "Mermaid源码同步验收")
                        var svg = false
                        for _ in 0..<100 {
                            svg =
                                (try await bridge.evaluateForValidation(
                                    "return !!document.querySelector('.diagram-preview svg')"))
                                as? Bool == true
                            if svg { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        try check(
                            svg && session.generation == 0,
                            "Mermaid renders locally without changing Markdown")
                        let state = try await query("中文起点", session: session)
                        try check(state.count == 1, "Diagram source is searched exactly once")
                        var highlighted = false
                        for _ in 0..<60 {
                            highlighted =
                                try await bridge.evaluateForValidation(
                                    "return !!document.querySelector('.diagram-block .source-search-current')"
                                ) as? Bool == true
                            if highlighted { break }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        try check(highlighted, "A diagram match expands and highlights its source")
                        _ = try await query("flowchart LR", session: session)
                        try await replace(session, with: "this is invalid mermaid")
                        try await Task.sleep(for: .milliseconds(600))
                        let hasError =
                            try await bridge.evaluateForValidation(
                                "return !!document.querySelector('.diagram-error')") as? Bool
                            == true
                        try check(
                            hasError && session.source.contains("this is invalid mermaid"),
                            "Invalid diagrams show an error and retain editable source")
                        await bridge.undo()
                        try await Task.sleep(for: .milliseconds(400))
                        let restored =
                            try await bridge.evaluateForValidation(
                                "return !!document.querySelector('.diagram-preview svg')") as? Bool
                            == true
                        try check(restored, "Undo restores the diagram preview")
                        try await close(session)
                        let wideCode =
                            "flowchart LR\n "
                            + (0..<18).map { "N\($0)[\"流程节点 \($0)\"]" }.joined(separator: " --> ")
                        let block = "```mermaid\n\(wideCode)\n```\n"
                        let (layoutSession, layoutBridge) = try await open(
                            "# 相同的宽流程图\n\n\(block)\n\(block)", name: "流程图宽度与缓存验收")
                        var twoDiagrams = false
                        for _ in 0..<100 {
                            twoDiagrams =
                                try await layoutBridge.evaluateForValidation(
                                    "return document.querySelectorAll('.diagram-preview svg').length === 2"
                                ) as? Bool == true
                            if twoDiagrams { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let unique =
                            try await layoutBridge.evaluateForValidation(
                                "const ids = [...document.querySelectorAll('.diagram-preview [id]')].map(el => el.id); return ids.length > 0 && new Set(ids).size === ids.length"
                            ) as? Bool == true
                        try check(
                            twoDiagrams && unique,
                            "Repeated cached diagrams keep independent SVG identifiers")
                        let scrolls =
                            try await layoutBridge.evaluateForValidation(
                                "[...document.querySelectorAll('.diagram-block button')].find(el => el.textContent === '原始大小').click(); await new Promise(resolve => setTimeout(resolve, 50)); const preview = document.querySelector('.diagram-preview'); return preview.dataset.scale === 'actual' && preview.scrollWidth > preview.clientWidth"
                            ) as? Bool == true
                        try check(
                            scrolls && layoutSession.generation == 0,
                            "Wide diagrams can scroll at original size without editing Markdown")
                        try await close(layoutSession)
                    } else if group == "large" {
                        guard
                            let fixture = Bundle.main.object(
                                forInfoDictionaryKey: "NRValidationManuscriptResource") as? String
                        else { throw Failure(message: "Synthetic fixture path is configured") }
                        guard let input = Bundle.main.resourceURL?.appendingPathComponent(fixture)
                        else { throw Failure(message: "Bundled fixture exists") }
                        let source = try String(contentsOf: input, encoding: .utf8)
                        let (session, bridge) = try await open(source, name: "长文档搜索与窗口验收")
                        let state = try await query("测试读者", session: session)
                        try check(state.count > 0, "Full-size manuscript search returns matches")
                        application.preferences.accentChoice = .purple
                        application.preferences.fontPercent = 110
                        application.preferences.appearance = .dark
                        let expectedAccent = application.preferences.accentHex
                        if let window = application.validationWindow(for: session) {
                            for width in [ReaderPreferences.minimumWindowSize.width, 1180] {
                                window.setFrame(
                                    NSRect(
                                        origin: window.frame.origin,
                                        size: NSSize(width: width, height: 760)), display: true)
                                try await Task.sleep(for: .milliseconds(120))
                            }
                            // AppKit ignores minSize when Auto Layout owns the window.
                            // Exercise the same delegate gate used by interactive resizing.
                            let permitted = window.delegate?.windowWillResize?(
                                window, to: NSSize(width: 640, height: 480))
                            try check(
                                permitted == ReaderPreferences.minimumWindowSize,
                                "Interactive resizing preserves the 640 × 640 search layout minimum"
                            )
                        }
                        var inspected: [String: Any] = [:]
                        var settingsReady = false
                        for _ in 0..<60 {
                            inspected =
                                try await bridge.evaluateForValidation(
                                    "const state = window.MyEditor.inspect(); return { mountCount: state.mountCount, search: state.search, accent: getComputedStyle(document.documentElement).getPropertyValue('--accent-color').trim(), highlighted: CSS.highlights.get('myeditor-find')?.size || 0 }"
                                ) as! [String: Any]
                            settingsReady =
                                (inspected["mountCount"] as? NSNumber)?.intValue == 1
                                && session.generation == 0
                                && inspected["accent"] as? String == expectedAccent
                                && ((inspected["highlighted"] as? NSNumber)?.intValue ?? 0) > 0
                            if settingsReady { break }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard settingsReady else {
                            throw Failure(
                                message:
                                    "Resize/settings did not settle: \(inspected), generation \(session.generation)"
                            )
                        }
                        try check(
                            settingsReady,
                            "Resize, font and accent preserve the editor and live highlights")
                        try await close(session)
                    } else if group == "fonts" {
                        let catalog = application.preferences.fontCatalog
                        try check(!catalog.families.isEmpty, "Installed font catalog is available")
                        try check(
                            !catalog.monospacedFamilies.isEmpty
                                && catalog.monospacedFamilies.allSatisfy {
                                    $0.faces.allSatisfy(\.monospaced)
                                }, "Code font catalog contains fixed-pitch faces only")
                        guard
                            let contentFamily = catalog.families.first(where: {
                                $0.familyName == "Times New Roman"
                            })
                                ?? catalog.families.first(where: {
                                    $0.faces.contains { !$0.monospaced }
                                }),
                            let codeFamily = catalog.monospacedFamilies.first(where: {
                                $0.familyName == "Menlo"
                            })
                                ?? catalog.monospacedFamilies.first
                        else {
                            throw Failure(message: "Representative installed fonts exist")
                        }
                        let contentFace = contentFamily.preferredFace
                        let codeFace = codeFamily.preferredFace
                        application.preferences.contentFont = .systemDefault
                        application.preferences.codeFont = .systemMonospaced
                        let source =
                            "# 字体切换\n\n正文示例 iiiWWW，表格如下。\n\n| 正文 | 内容 |\n| - | - |\n| 字体 | 验收 |\n\n行内代码 `let value = 1`。\n\n```swift\nlet value = 1\n```\n\n```mermaid\nflowchart LR\n A[\"字体\"] --> B[\"切换\"]\n```\n"
                        let (session, bridge) = try await open(source, name: "本机字体切换验收")
                        application.preferences.contentFont = contentFace.selection
                        application.preferences.codeFont = codeFace.selection
                        var inspected: [String: Any] = [:]
                        var fontsReady = false
                        for _ in 0..<120 {
                            inspected =
                                try await bridge.evaluateForValidation(
                                    """
                                    const content = document.querySelector('.document-content p');
                                    const inlineCode = document.querySelector('.document-content p code');
                                    const code = document.querySelector('.source-editor .cm-scroller');
                                    const toolbar = document.querySelector('.source-toolbar');
                                    const svg = document.querySelector('.diagram-preview svg');
                                    const measure = family => {
                                      const sample = document.createElement('span');
                                      sample.textContent = 'iiiiiiiiMMMMMMMM中文字体';
                                      sample.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;font-size:32px';
                                      sample.style.fontFamily = family;
                                      document.body.append(sample);
                                      const width = sample.getBoundingClientRect().width;
                                      sample.remove();
                                      return width;
                                    };
                                    const rootStyle = getComputedStyle(document.documentElement);
                                    const contentStyle = content && getComputedStyle(content);
                                    return {
                                      mountCount: window.MyEditor.inspect().mountCount,
                                      contentVariable: rootStyle.getPropertyValue('--content-font-family').trim(),
                                      codeVariable: rootStyle.getPropertyValue('--code-font-family').trim(),
                                      contentFamily: contentStyle?.fontFamily || '',
                                      inlineCodeFamily: inlineCode ? getComputedStyle(inlineCode).fontFamily : '',
                                      codeFamily: code ? getComputedStyle(code).fontFamily : '',
                                      uiFamily: toolbar ? getComputedStyle(toolbar).fontFamily : '',
                                      customWidth: contentStyle ? measure(contentStyle.fontFamily) : 0,
                                      systemWidth: measure('-apple-system, BlinkMacSystemFont, sans-serif'),
                                      mermaidFont: svg?.querySelector('style[data-myeditor-font]')?.textContent || '',
                                      mermaidSignature: svg?.getAttribute('data-myeditor-font-signature') || ''
                                    };
                                    """
                                ) as! [String: Any]
                            let contentReady =
                                (inspected["contentVariable"] as? String)?.contains(
                                    contentFace.familyName) == true
                            let codeReady =
                                (inspected["codeVariable"] as? String)?.contains(
                                    codeFace.familyName) == true
                            let mermaidReady =
                                (inspected["mermaidSignature"] as? String)?.contains(
                                    contentFace.familyName) == true
                            if contentReady && codeReady && mermaidReady {
                                fontsReady = true
                                break
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard fontsReady else {
                            throw Failure(
                                message: "Font configuration did not settle: \(inspected)")
                        }
                        try check(
                            (inspected["contentFamily"] as? String)?.contains(
                                contentFace.familyName) == true,
                            "Body and table content use the selected local face")
                        try check(
                            (inspected["inlineCodeFamily"] as? String)?.contains(
                                codeFace.familyName) == true
                                && (inspected["codeFamily"] as? String)?.contains(
                                    codeFace.familyName) == true,
                            "Inline code and CodeMirror use the selected fixed-pitch face")
                        let customWidth = (inspected["customWidth"] as? NSNumber)?.doubleValue ?? 0
                        let systemWidth = (inspected["systemWidth"] as? NSNumber)?.doubleValue ?? 0
                        try check(
                            abs(customWidth - systemWidth) > 0.5,
                            "Connected WKWebView renders different glyph metrics for the selected body font"
                        )
                        try check(
                            (inspected["uiFamily"] as? String)?.contains(contentFace.familyName)
                                != true
                                && (inspected["uiFamily"] as? String)?.contains(codeFace.familyName)
                                    != true,
                            "Editor controls keep the system UI font")
                        try check(
                            (inspected["mermaidFont"] as? String)?.contains(contentFace.familyName)
                                == true, "Mermaid labels receive the selected body face")
                        let savedContent = UserDefaults.standard.data(forKey: "reader.contentFont")
                            .flatMap {
                                try? JSONDecoder().decode(EditorFontSelection.self, from: $0)
                            }
                        let savedCode = UserDefaults.standard.data(forKey: "reader.codeFont")
                            .flatMap {
                                try? JSONDecoder().decode(EditorFontSelection.self, from: $0)
                            }
                        try check(
                            savedContent == contentFace.selection
                                && savedCode == codeFace.selection,
                            "Font selections persist by PostScript face name")
                        application.preferences.contentFont = .installed(
                            postScriptName: "MyEditor-Missing-Font")
                        var missingFallback = false
                        for _ in 0..<60 {
                            let family =
                                try await bridge.evaluateForValidation(
                                    "return getComputedStyle(document.documentElement).getPropertyValue('--content-font-family').trim()"
                                ) as? String
                            if family?.hasPrefix("system-ui") == true {
                                missingFallback = true
                                break
                            }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        try check(
                            missingFallback
                                && application.preferences.contentFont
                                    == .installed(postScriptName: "MyEditor-Missing-Font"),
                            "Unavailable fonts retain the preference and fall back to the system face"
                        )
                        let finalState =
                            try await bridge.evaluateForValidation(
                                "return window.MyEditor.inspect()") as! [String: Any]
                        try check(
                            (finalState["mountCount"] as? NSNumber)?.intValue == 1
                                && session.generation == 0
                                && session.source == source && !session.hasUnsavedChanges,
                            "Live font changes preserve one editor instance and never mutate Markdown"
                        )
                        try await close(session)
                    } else {
                        let (session, bridge) = try await open("", name: "空文档搜索验收")
                        let state = try await query("关键词", session: session)
                        try check(
                            state.count == 0 && !state.canReplace && !session.isEditing,
                            "Empty/no-match documents disable replacement")
                        _ = try await query("", session: session)
                        let inspected =
                            try await bridge.evaluateForValidation(
                                "return window.MyEditor.inspect()") as! [String: Any]
                        try check(
                            inspected["source"] as? String == "" && !session.hasUnsavedChanges,
                            "Clearing search keeps an empty document untouched")
                        try await close(session)
                    }
                    results[group] = ["passed": true, "checks": completed]
                } catch {
                    let message = (error as? Failure)?.message ?? error.localizedDescription
                    results[group] = ["passed": false, "checks": completed, "failure": message]
                }
                let progress: [String: Any] = [
                    "status": "running", "phase": phase, "groups": results,
                ]
                if let data = try? JSONSerialization.data(
                    withJSONObject: progress, options: [.prettyPrinted, .sortedKeys])
                {
                    try? data.write(to: reportURL, options: .atomic)
                }
            }
            application.preferences.accentChoice = originalAccent
            application.preferences.fontPercent = originalFont
            application.preferences.contentFont = originalContentFont
            application.preferences.codeFont = originalCodeFont
            application.preferences.appearance = originalTheme
            application.preferences.rememberWindowSize(originalSize)
            let passed = results.values.allSatisfy {
                ($0 as? [String: Any])?["passed"] as? Bool == true
            }
            let report: [String: Any] = [
                "status": "completed", "passed": passed, "phase": phase, "groups": results,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            {
                try? data.write(to: reportURL, options: .atomic)
            }
            // The user's source is only read. Leave a disposable copy for the one UI pass.
            if let source = try? String(
                contentsOf: directory.appendingPathComponent("流程图.md"), encoding: .utf8)
            {
                _ = try? await open(source, name: "流程图窗口验收")
            }
        }
    }
#endif
