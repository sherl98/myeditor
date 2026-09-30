#if DEBUG
    import AppKit
    import ManuscriptCore

    @MainActor enum TypographyIntegrationChecks {
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw FeatureIntegrationChecks.Failure(message: message) }
                checks.append(message)
            }
            let source = """
                # 小窗口里的阅读与写作

                ## 留一点呼吸的空间

                清晨的杭州，街角咖啡店刚刚开门。打开MacBook，读完昨天留下的Markdown文稿，再写下今天的第一句话。字体不必很大，行与行之间却要看得清楚。

                清晨的窗外还笼着一层薄雾，沿河的石板路渐渐有了脚步声。她把昨天读到一半的书放回桌上，推开窗，听见楼下有人招呼卖花的姑娘。河对岸的树影映在水里，偶尔被一只经过的小船轻轻打散，又慢慢聚在一起。

                中西文混排很常见：macOS 26、API接口、版本2.0，以及英文句子 Read a little, write a little. 自动间距应该让文字更舒展，也应该保留原文中的每一个字符。

                “一句话还没有说完，”她停了一下，“不要把标点留在下一行。”（括号内的文字也是如此。）

                Read a little, write a little. A quiet page gives each paragraph room to breathe, while the last line ends naturally. Inline **formatting** and [links](https://example.com) should preserve the text and its reading order.

                > 引文也应该保持平稳的右边缘。窗前的桌上摊着几本旧书，有人夹了一片银杏叶在书页间，又在旁边写下了一句很短的话，等到下次读到这里的时候再想起这个清晨。

                显式换行第一行。\\
                第二行保持原来的起点。

                | 名称 | 说明 |
                | --- | --- |
                | API | 表格里的短文本维持原有对齐方式。 |

                ## 不打断思路

                - 阅读时让段落自然断行。
                - 编辑时保持光标附近的文字稳定。
                - 代码 `中文API` 保留自己的间距。

                ```swift
                let message = "中文API"
                ```

                """
            let destination = directory.appendingPathComponent("窄窗口排版验收.md")
            try source.write(to: destination, atomically: true, encoding: .utf8)
            application.open([destination])
            await application.waitForValidationOpen()
            guard let session = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: "Typography document opens")
            }
            for _ in 0..<200 {
                if session.editorReady { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            guard let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                let window = application.validationWindow(for: session),
                let webView = bridge.webView
            else {
                throw FeatureIntegrationChecks.Failure(
                    message: "Typography editor and window exist")
            }
            application.preferences.fontPercent = 100
            application.setAppearance(.light)
            var measurements: [[String: Any]] = []
            for (width, percent) in [(480, 100), (640, 100), (960, 100), (480, 140), (640, 80)] {
                application.preferences.fontPercent = percent
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 800)),
                    display: true)
                try await Task.sleep(for: .milliseconds(350))
                var state =
                    try await bridge.evaluateForValidation(
                        """
                        const content = document.querySelector('.document-content');
                        const style = getComputedStyle(content);
                        const rect = content.getBoundingClientRect();
                        const paragraphs = [...content.querySelectorAll(':scope > p, blockquote > p')];
                        function lines(p) {
                          const result = [];
                          const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
                          for (let node; (node = walker.nextNode());) {
                            let offset = 0;
                            for (const character of node.textContent) {
                              const start = offset;
                              offset += character.length;
                              // Range includes hanging English spaces; measure visible glyphs only.
                              if (character.trim() === '') continue;
                              const range = document.createRange();
                              range.setStart(node, start);
                              range.setEnd(node, offset);
                              const box = [...range.getClientRects()].filter(box => box.width && box.height).at(-1);
                              if (!box) continue;
                              let line = result.find(line => Math.abs(line.top - box.top) < 3);
                              if (!line) { line = { top: box.top, left: box.left, right: box.right, text: '' }; result.push(line); }
                              line.left = Math.min(line.left, box.left);
                              line.right = Math.max(line.right, box.right);
                              line.text += character;
                            }
                          }
                          return result.sort((a, b) => a.top - b.top);
                        }
                        const prose = paragraphs.filter(p => !p.querySelector('br') && p.dataset.script !== 'latin');
                        const latin = paragraphs.filter(p => p.dataset.script === 'latin');
                        const gaps = prose.flatMap(p => lines(p).slice(0, -1).map(line => p.getBoundingClientRect().right - line.right));
                        const tails = prose.map(p => p.getBoundingClientRect().right - lines(p).at(-1).right);
                        const fixedBreak = paragraphs.find(p => p.querySelector('br'));
                        const excluded = [...content.querySelectorAll('h1, h2, li, td p, th p, pre, .cm-editor')];
                        return { font: parseFloat(style.fontSize), line: parseFloat(style.lineHeight),
                          width: rect.width, fits: rect.left >= 0 && rect.right <= innerWidth + 1,
                          left: rect.left, right: rect.right,
                          viewport: innerWidth, clientWidth: document.documentElement.clientWidth,
                          clientLeft: document.documentElement.clientLeft,
                          rootLeft: document.documentElement.getBoundingClientRect().left,
                          gutter: getComputedStyle(document.documentElement).scrollbarGutter,
                          autospace: style.textAutospace, wrap: style.textWrapStyle,
                          lines: gaps.length, maxRightGap: Math.max(...gaps.map(Math.abs)),
                          paragraphs: prose.map(p => ({ text: p.textContent, align: getComputedStyle(p).textAlign,
                            gaps: lines(p).map(line => p.getBoundingClientRect().right - line.right) })),
                          punctuation: prose.every(p => lines(p).every(line => !/^[，。、；：？！）】》」』]/u.test(line.text) && !/[（【《「『]$/u.test(line.text))),
                          naturalTails: tails.some(gap => gap > parseFloat(style.fontSize)),
                          hardBreakPreserved: lines(fixedBreak).length === 2 && lines(fixedBreak)[0].right < fixedBreak.getBoundingClientRect().right - parseFloat(style.fontSize),
                          excluded: excluded.every(element => getComputedStyle(element).textAlign !== 'justify'),
                          latinAlign: latin.map(p => getComputedStyle(p).textAlign),
                          spacingTrim: CSS.supports('text-spacing-trim', 'trim-start'),
                          code: getComputedStyle(content.querySelector('code')).textAutospace };
                        """) as! [String: Any]
                let webFrame = webView.convert(webView.bounds, to: window.contentView)
                state["webFrame"] = NSStringFromRect(webFrame)
                // WebKit's DOM rects exclude the leading root scrollbar gutter;
                // the native snapshot includes it. Convert to painted window coordinates.
                let gutterInset =
                    ((state["viewport"] as? Double ?? 0) - (state["clientWidth"] as? Double ?? 0))
                    / 2
                let leftMargin = webFrame.minX + gutterInset + (state["left"] as? Double ?? -1000)
                let rightMargin =
                    (window.contentView?.bounds.width ?? 0) - webFrame.minX - gutterInset
                    - (state["right"] as? Double ?? -1000)
                state["viewportGutterInset"] = gutterInset
                state["windowLeftMargin"] = leftMargin
                state["windowRightMargin"] = rightMargin
                measurements.append(
                    state.merging(["windowWidth": width, "fontPercent": percent]) {
                        _, new in new
                    })
                try JSONSerialization.data(
                    withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]
                )
                .write(to: directory.appendingPathComponent("typography-measurements.json"))
                if width <= 640 && percent == 100 {
                    let image = try await webView.takeSnapshot(configuration: nil)
                    if let data = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: data),
                        let png = bitmap.representation(using: .png, properties: [:])
                    {
                        try png.write(
                            to: directory.appendingPathComponent("typography-\(width).png"))
                    }
                }
                let font = (state["font"] as? NSNumber)?.doubleValue ?? 0
                try check(
                    abs(leftMargin - rightMargin) < 1 && leftMargin >= 66,
                    "Page margins match within 1pt and clear the chapter rail at \(width)pt / \(percent)%"
                )
                try check(
                    abs(font - 18 * Double(percent) / 100) < 0.1 && state["fits"] as? Bool == true,
                    "Fixed type fits a \(width)pt window at manual \(percent)% scale")
                try check(
                    state["wrap"] as? String == "stable"
                        && (state["lines"] as? Int ?? 0) > 3
                        && (state["maxRightGap"] as? Double ?? 999) < 1
                        && state["naturalTails"] as? Bool == true,
                    "Non-final prose lines align within 1px and final lines remain natural at \(width)pt / \(percent)%"
                )
                try check(
                    state["hardBreakPreserved"] as? Bool == true
                        && state["punctuation"] as? Bool == true
                        && state["excluded"] as? Bool == true
                        && state["code"] as? String == "no-autospace",
                    "Hard breaks, headings, lists, tables and code retain their own layout at \(width)pt / \(percent)%"
                )
                try check(
                    (state["latinAlign"] as? [String]) == ["start"],
                    "A Latin-script paragraph is start-aligned instead of justified at \(width)pt / \(percent)%"
                )
            }
            application.preferences.fontPercent = 120
            try await Task.sleep(for: .milliseconds(200))
            let enlarged =
                try await bridge.evaluateForValidation(
                    "return parseFloat(getComputedStyle(document.querySelector('.document-content')).fontSize)"
                ) as? NSNumber
            try check(
                abs((enlarged?.doubleValue ?? 0) - 21.6) < 0.1,
                "Manual font control alone changes the font to 21.6px at 120%")
            application.toggleEditing(session)
            try await Task.sleep(for: .milliseconds(200))
            let wrap =
                try await bridge.evaluateForValidation(
                    "return getComputedStyle(document.querySelector('.document-content')).textWrapStyle"
                ) as? String
            try check(wrap == "stable", "Editing uses stable line wrapping")
            let editingAlign =
                try await bridge.evaluateForValidation(
                    "return getComputedStyle(document.querySelector('.document-content > p')).textAlign"
                ) as? String
            try check(editingAlign != "justify", "Editing retains natural spacing around the caret")
            application.toggleEditing(session)
            try await Task.sleep(for: .milliseconds(250))
            let readingState =
                try await bridge.evaluateForValidation(
                    """
                    return { align: getComputedStyle(document.querySelector('.document-content > p')).textAlign,
                      source: MyEditor.inspect().source, canUndo: MyEditor.inspect().canUndo };
                    """) as! [String: Any]
            try check(
                readingState["align"] as? String == "justify"
                    && readingState["source"] as? String == source
                    && readingState["canUndo"] as? Bool == false,
                "Returning to reading restores justification without changing text or undo history")
            try check(
                session.generation == 0 && !session.hasUnsavedChanges
                    && (try String(contentsOf: destination, encoding: .utf8)) == source,
                "Typography, resizing and mode changes preserve Markdown bytes")
            session.showsSource = true
            try await Task.sleep(for: .milliseconds(250))
            let sourceLeft =
                try await bridge.evaluateForValidation(
                    "return document.querySelector('.source-document').getBoundingClientRect().left"
                ) as? Double ?? -1
            try check(sourceLeft >= 62, "Source preview and line numbers clear the chapter rail")
            application.preferences.fontPercent = 100
            application.requestClose(session)

            let plainSource = "没有章节导航的短文，也应该在整个窗口里保持左右等宽的留白。"
            let plainURL = directory.appendingPathComponent("无标题边距验收.md")
            try plainSource.write(to: plainURL, atomically: true, encoding: .utf8)
            application.open([plainURL])
            await application.waitForValidationOpen()
            guard let plainSession = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: "Plain document opens")
            }
            for _ in 0..<200 {
                if plainSession.editorReady { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            guard
                let plainBridge = application.editor(for: plainSession)
                    as? MarkdownWebEditor.Coordinator,
                let plainWindow = application.validationWindow(for: plainSession),
                let plainWeb = plainBridge.webView
            else {
                throw FeatureIntegrationChecks.Failure(message: "Plain document editor exists")
            }
            try await Task.sleep(for: .milliseconds(250))
            let plainEdges =
                try await plainBridge.evaluateForValidation(
                    "const r = document.querySelector('.document-content').getBoundingClientRect(); return {left: r.left, right: r.right, inset: (innerWidth - document.documentElement.clientWidth) / 2}"
                ) as! [String: Any]
            let plainFrame = plainWeb.convert(plainWeb.bounds, to: plainWindow.contentView)
            let plainInset = plainEdges["inset"] as? Double ?? 0
            let plainLeft = plainFrame.minX + plainInset + (plainEdges["left"] as? Double ?? -1000)
            let plainRight =
                (plainWindow.contentView?.bounds.width ?? 0) - plainFrame.minX - plainInset
                - (plainEdges["right"] as? Double ?? -1000)
            try check(
                plainSession.primaryHeadings.isEmpty && abs(plainLeft - plainRight) < 1,
                "A short document without the chapter rail also has equal window margins")
            application.requestClose(plainSession)
            return checks
        }
    }
#endif
