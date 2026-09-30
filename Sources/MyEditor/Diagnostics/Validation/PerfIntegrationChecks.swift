#if DEBUG
    import AppKit
    import Darwin
    import ManuscriptCore
    import WebKit

    /// Repeatable WKWebView measurements. Correctness is asserted; timings are recorded.
    @MainActor enum PerfIntegrationChecks {
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            var checks: [String] = []
            func check(_ condition: Bool, _ message: String) throws {
                guard condition else { throw FeatureIntegrationChecks.Failure(message: message) }
                checks.append(message)
            }
            guard
                let fixture = Bundle.main.object(
                    forInfoDictionaryKey: "NRValidationManuscriptResource") as? String,
                let input = Bundle.main.resourceURL?.appendingPathComponent(fixture)
            else { throw FeatureIntegrationChecks.Failure(message: "Synthetic fixture exists") }
            let large = try String(contentsOf: input, encoding: .utf8)
            var report: [String: Any] = [:]
            func write() throws {
                let data = try JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appendingPathComponent("perf.json"))
            }
            for (name, source) in [
                ("large", large), ("xlarge", String(repeating: large, count: 6)),
            ] {
                report[name] = try await measureTyping(
                    name: name, source: source, application: application, directory: directory)
                try write()
            }
            report["tabs"] = try await measureTabs(application: application, directory: directory)
            try write()
            for name in ["large", "xlarge"] {
                let result = report[name] as? [String: Any] ?? [:]
                try check(
                    result["inserted"] as? Bool == true && result["flushed"] as? Bool == true,
                    "\(name): typed text reaches the native source")
            }
            try check(
                (report["tabs"] as? [String: Any])?["tabs"] as? Int == 5,
                "Five small documents open in separate tabs")
            return checks
        }

        private static func measureTyping(
            name: String, source: String, application: ApplicationController, directory: URL
        ) async throws -> [String: Any] {
            let url = directory.appendingPathComponent("perf-\(name).md")
            try source.write(to: url, atomically: true, encoding: .utf8)
            let clock = ContinuousClock()
            let opened = clock.now
            application.open([url])
            await application.waitForValidationOpen()
            guard let session = application.activeSession else {
                throw FeatureIntegrationChecks.Failure(message: "\(name) opens")
            }
            try await wait("\(name) editor ready") { session.editorReady }
            let loadMilliseconds = milliseconds(clock.now - opened)
            guard let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                let webView = bridge.webView,
                let window = application.validationWindow(for: session)
            else { throw FeatureIntegrationChecks.Failure(message: "\(name) bridge exists") }
            application.toggleEditing(session)
            try await wait("\(name) enters editing") { session.isEditing }
            var editable = false
            for _ in 0..<150 where !editable {
                editable =
                    try await bridge.evaluateForValidation(
                        "return document.querySelector('.document-content')?.isContentEditable === true"
                    ) as? Bool == true
                if !editable { try await Task.sleep(for: .milliseconds(100)) }
            }
            guard editable else {
                throw FeatureIntegrationChecks.Failure(message: "\(name) becomes editable")
            }
            let placed =
                try await bridge.evaluateForValidation(
                    """
                    const paragraph = document.querySelectorAll('.document-content p')[3];
                    const node = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT).nextNode();
                    const content = document.querySelector('.document-content');
                    content.focus({ preventScroll: true });
                    paragraph.scrollIntoView({ block: 'center' });
                    const range = document.createRange();
                    range.setStart(node, 5);
                    range.collapse(true);
                    const selection = getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    window.__perf = { costs: [], frames: [], running: true };
                    if (!window.__perfInstalled) {
                      window.__perfInstalled = true;
                      document.addEventListener('beforeinput', () => {
                        const start = performance.now();
                        setTimeout(() => window.__perf.costs.push(performance.now() - start), 0);
                      }, true);
                    }
                    const loop = (time) => {
                      if (!window.__perf.running) return;
                      window.__perf.frames.push(time);
                      requestAnimationFrame(loop);
                    };
                    requestAnimationFrame(loop);
                    return !content.getAttribute('contenteditable') || content.isContentEditable;
                    """) as? Bool == true
            guard placed else { throw FeatureIntegrationChecks.Failure(message: "\(name) caret") }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
            try await Task.sleep(for: .milliseconds(200))
            let generation = session.generation
            let keys = 40
            for _ in 0..<keys {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: "x",
                        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)
                    {
                        window.sendEvent(event)
                    }
                }
                try await Task.sleep(for: .milliseconds(35))
            }
            // Keys queue behind a busy page. Measure how long the backlog takes to drain.
            let lastKey = clock.now
            var drained = false
            for _ in 0..<300 where !drained {
                drained =
                    (try await bridge.evaluateForValidation(
                        "return window.__perf.costs.length")) as? Int ?? 0 >= keys
                if !drained { try await Task.sleep(for: .milliseconds(50)) }
            }
            let backlogMilliseconds = milliseconds(clock.now - lastKey)
            try await Task.sleep(for: .milliseconds(1200))
            let collected =
                try await bridge.evaluateForValidation(
                    "window.__perf.running = false; return { costs: window.__perf.costs, frames: window.__perf.frames }"
                ) as? [String: Any] ?? [:]
            let changeMessages = Int(session.generation - generation)
            let flushStarted = clock.now
            let flushed = await application.flushEditor(session)
            let flushMilliseconds = milliseconds(clock.now - flushStarted)
            let typed = session.source.filter { $0 == "x" }.count
            let inserted = session.source.contains(String(repeating: "x", count: keys))
            let costs = (collected["costs"] as? [Double] ?? []).sorted()
            let frames = collected["frames"] as? [Double] ?? []
            let gaps = zip(frames.dropFirst(), frames).map { $0 - $1 }
            let memory: [String: Any] = [
                "nativeMB": footprintMB(getpid()),
                "webContentMB": webProcessIdentifier(webView).map { footprintMB($0) } ?? -1,
            ]
            await application.save(session, reason: .explicit)
            application.requestClose(session)
            try await wait("\(name) closes") { session.isClosed }
            return [
                "characters": source.count,
                "loadMilliseconds": loadMilliseconds,
                "keys": keys,
                "inputEvents": costs.count,
                "inputToIdleMs": [
                    "p50": percentile(costs, 0.5), "p95": percentile(costs, 0.95),
                    "max": costs.last ?? 0,
                ],
                "longFramesOver50ms": gaps.filter { $0 > 50 }.count,
                "maxFrameGapMs": gaps.max() ?? 0,
                "changeMessages": changeMessages,
                "flushMilliseconds": flushMilliseconds,
                "backlogAfterLastKeyMs": backlogMilliseconds,
                "flushed": flushed,
                "inserted": inserted,
                "typedCharacters": typed,
                "memory": memory,
            ]
        }

        private static func measureTabs(application: ApplicationController, directory: URL)
            async throws -> [String: Any]
        {
            var sessions: [DocumentSession] = []
            for index in 1...5 {
                let url = directory.appendingPathComponent("perf-tab-\(index).md")
                try "# 第 \(index) 份\n\n## 第一章\n\n窗外下着雨。\n\n## 第二章\n\n夜色渐深。\n".write(
                    to: url, atomically: true, encoding: .utf8)
                application.open([url])
                await application.waitForValidationOpen()
                guard let session = application.activeSession else { continue }
                try await wait("Tab \(index) ready") { session.editorReady }
                sessions.append(session)
            }
            try await Task.sleep(for: .seconds(2))
            var web: [Double] = []
            for session in sessions {
                if let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                    let webView = bridge.webView, let pid = webProcessIdentifier(webView)
                {
                    web.append(footprintMB(pid))
                }
            }
            let native = footprintMB(getpid())
            for session in sessions {
                application.requestClose(session)
                try await wait("Tab closes") { session.isClosed }
            }
            return [
                "tabs": sessions.count, "nativeMB": native, "webContentMB": web,
                "totalMB": native + web.reduce(0, +),
            ]
        }

        private static func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<750 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw FeatureIntegrationChecks.Failure(message: message)
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }

        private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }

        private static func webProcessIdentifier(_ webView: WKWebView) -> pid_t? {
            let selector = NSSelectorFromString("_webProcessIdentifier")
            guard webView.responds(to: selector) else { return nil }
            return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
        }

        private static func footprintMB(_ pid: pid_t) -> Double {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            return status == 0 ? (Double(info.ri_phys_footprint) / 1_048_576).rounded() : -1
        }
    }
#endif
