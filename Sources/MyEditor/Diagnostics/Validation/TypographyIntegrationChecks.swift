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

                中西文混排很常见：macOS 26、API接口、版本2.0，以及英文句子 Read a little, write a little. 自动间距应该让文字更舒展，也应该保留原文中的每一个字符。

                “一句话还没有说完，”她停了一下，“不要把标点留在下一行。”（括号内的文字也是如此。）

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
            for width in [480, 640, 960] {
                window.setFrame(
                    NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 800)),
                    display: true)
                try await Task.sleep(for: .milliseconds(350))
                let state =
                    try await bridge.evaluateForValidation(
                        """
                        const content = document.querySelector('.document-content');
                        const style = getComputedStyle(content);
                        const rect = content.getBoundingClientRect();
                        return { font: parseFloat(style.fontSize), line: parseFloat(style.lineHeight),
                          width: rect.width, fits: rect.left >= 0 && rect.right <= innerWidth + 1,
                          autospace: style.textAutospace, wrap: style.textWrapStyle,
                          supported: CSS.supports('text-autospace', 'ideograph-alpha ideograph-numeric') && CSS.supports('text-wrap-style', 'pretty'),
                          code: getComputedStyle(content.querySelector('code')).textAutospace };
                        """) as! [String: Any]
                let font = (state["font"] as? NSNumber)?.doubleValue ?? 0
                try check(
                    abs(font - 18) < 0.1 && state["fits"] as? Bool == true,
                    "Fixed 18px type fits a \(width)pt window without automatic font scaling")
                try check(
                    state["supported"] as? Bool == true && state["wrap"] as? String == "pretty"
                        && state["code"] as? String == "no-autospace",
                    "Native reading typography is active and code spacing is excluded at \(width)pt"
                )
                if width <= 640 {
                    let image = try await webView.takeSnapshot(configuration: nil)
                    if let data = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: data),
                        let png = bitmap.representation(using: .png, properties: [:])
                    {
                        try png.write(
                            to: directory.appendingPathComponent("typography-\(width).png"))
                    }
                }
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
            try check(
                session.generation == 0 && !session.hasUnsavedChanges
                    && (try String(contentsOf: destination, encoding: .utf8)) == source,
                "Typography, resizing and mode changes preserve Markdown bytes")
            application.preferences.fontPercent = 100
            application.requestClose(session)
            return checks
        }
    }
#endif
