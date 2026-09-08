import AppKit
import ManuscriptCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor protocol MarkdownEditorControlling: AnyObject {
    func flush(commitComposition: Bool) async -> Bool
    func undo() async
    func redo() async
    func setAppearance(_ appearance: String, resolvedDark: Bool) async -> Bool
    func navigate(to id: String)
    func focusDocument()
    func recover()
    func search(query: String, requestID: Int, direction: Int?)
    func clearSearch(requestID: Int) async -> Bool
    func replace(query: String, replacement: String, all: Bool, requestID: Int) async -> Int?
}

@MainActor final class WeakMarkdownEditor {
    weak var value: (any MarkdownEditorControlling)?
    init(_ value: any MarkdownEditorControlling) { self.value = value }
}

/// Read observable settings in SwiftUI's body, before the asynchronous web view
/// is ready. Otherwise the coordinator's early return leaves no dependencies
/// for subsequent appearance, font or mode changes to invalidate.
struct MarkdownEditorConfiguration: Equatable {
    let revision: UInt64
    let readOnly: Bool
    let showsSource: Bool
    let fontPercent: Int
    let contentFontFace: EditorWebFontFace
    let codeFontFace: EditorWebFontFace
    let fontCatalogRevision: UInt64
    let appearance: String
    let resolvedDarkAppearance: Bool
    let accent: String
    let preserveFocus: Bool
    let railOffset: Int
    let bodyOpticalOffset: Int

    @MainActor init(
        session: DocumentSession, application: ApplicationController, railOffset: Int,
        bodyOpticalOffset: Int
    ) {
        revision = session.documentRevision
        readOnly = !session.isEditing || session.isClosing
        showsSource = session.showsSource
        fontPercent = application.preferences.fontPercent
        contentFontFace = application.preferences.fontCatalog.webFace(
            for: application.preferences.contentFont, role: .content)
        codeFontFace = application.preferences.fontCatalog.webFace(
            for: application.preferences.codeFont, role: .code)
        fontCatalogRevision = application.preferences.fontCatalog.revision
        appearance = application.preferences.appearance.rawValue
        resolvedDarkAppearance = application.preferences.resolvedDarkAppearance
        accent = application.preferences.accentHex
        preserveFocus = !application.searchState(for: session).query.isEmpty
        self.railOffset = railOffset
        self.bodyOpticalOffset = bodyOpticalOffset
    }
    var webOptions: [String: Any] {
        [
            "readOnly": readOnly, "showsSource": showsSource, "fontPercent": fontPercent,
            "contentFontFace": contentFontFace.webOptions, "codeFontFace": codeFontFace.webOptions,
            "appearance": appearance,
            "resolvedDarkAppearance": resolvedDarkAppearance,
            "accent": accent, "preserveFocus": preserveFocus, "railOffset": railOffset,
            "bodyOpticalOffset": bodyOpticalOffset,
        ]
    }
}

struct MarkdownWebEditor: NSViewRepresentable {
    let session: DocumentSession
    let application: ApplicationController
    let configuration: MarkdownEditorConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, application: application, configuration: configuration)
    }
    func makeNSView(context: Context) -> MarkdownWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "myEditor")
        configuration.setURLSchemeHandler(
            DocumentImageHandler(directory: session.url.deletingLastPathComponent()),
            forURLScheme: "myeditor-resource")
        let webView = MarkdownWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityLabel("Markdown 文档正文")
        webView.registerForDraggedTypes(webView.registeredDraggedTypes + [.fileURL])
        context.coordinator.webView = webView
        application.registerEditor(context.coordinator, for: session)
        if let html = Self.editorHTML {
            // The bundle is a self-contained page. Do not give each WebKit
            // process filesystem access to a bundle in Documents/Downloads.
            // Document text arrives over the bridge; local images use the
            // existing native resource handler, with the page's CSP intact.
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            session.reportEditorFailure()
            webView.loadHTMLString(
                "<html lang='zh'><body><p>未找到本地编辑器资源。请使用完整的 MyEditor.app。</p></body></html>",
                baseURL: nil)
        }
        return webView
    }
    func updateNSView(_ view: MarkdownWKWebView, context: Context) {
        context.coordinator.update(reduceMotion: reduceMotion, configuration: configuration)
    }
    static func dismantleNSView(_ view: MarkdownWKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "myEditor")
        view.navigationDelegate = nil
    }
    private static var resourceURL: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("EditorWeb/index.html"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
                "EditorWeb/dist/index.html"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
    private static let editorHTML: String? = {
        guard let resource = resourceURL else { return nil }
        return try? String(contentsOf: resource, encoding: .utf8)
    }()

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
        MarkdownEditorControlling
    {
        let session: DocumentSession
        unowned let application: ApplicationController
        weak var webView: MarkdownWKWebView?
        private var ready = false
        private var loadedRevision: UInt64?
        private var configuration: MarkdownEditorConfiguration
        private var appliedConfiguration: MarkdownEditorConfiguration?
        private var reduceMotion = false
        private var wheelMonitor: Any?
        static var activeWheelMonitors = 0

        init(
            session: DocumentSession, application: ApplicationController,
            configuration: MarkdownEditorConfiguration
        ) {
            self.session = session
            self.application = application
            self.configuration = configuration
            super.init()
            session.prepareForExternalReload = { [weak self] in
                guard let self else { return true }
                return await self.flush(commitComposition: false)
            }
        }
        func detach() {
            removeWheelMonitor()
            application.unregisterEditor(for: session)
            session.setEditorReady(false)
            session.prepareForExternalReload = nil
        }
        func update(reduceMotion: Bool, configuration: MarkdownEditorConfiguration) {
            self.reduceMotion = reduceMotion
            self.configuration = configuration
            updateWheelMonitor()
            guard ready else { return }
            if loadedRevision != session.documentRevision {
                loadDocument()
                return
            }
            guard configuration != appliedConfiguration else { return }
            appliedConfiguration = configuration
            webView?.callAsyncJavaScript(
                "window.MyEditor.configure(options)",
                arguments: ["options": configuration.webOptions], in: nil, in: .page,
                completionHandler: nil)
        }
        private func loadDocument() {
            guard let webView else { return }
            var options = configuration.webOptions
            options["source"] = session.source
            options["sessionID"] = session.id.uuidString
            options["revision"] = session.documentRevision
            options["preserveScroll"] = loadedRevision != nil
            #if DEBUG
                options["validation"] =
                    Bundle.main.object(forInfoDictionaryKey: "NRRunEditorChecks") as? Bool == true
                    || Bundle.main.object(forInfoDictionaryKey: "NRRunFeatureChecks") as? Bool
                        == true
            #endif
            loadedRevision = session.documentRevision
            application.searchState(for: session).resetForReload()
            session.setEditorReady(false)
            appliedConfiguration = nil
            webView.callAsyncJavaScript(
                "return await window.MyEditor.load(options)", arguments: ["options": options],
                in: nil, in: .page
            ) { [weak self] result in
                if case .failure = result { self?.session.reportEditorFailure() }
            }
        }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String
            else { return }
            if type == "ready" {
                ready = true
                loadDocument()
                return
            }
            guard body["sessionID"] as? String == session.id.uuidString,
                (body["revision"] as? NSNumber)?.uint64Value == session.documentRevision
            else { return }
            switch type {
            case "loaded":
                session.setEditorReady(true)
                update(reduceMotion: reduceMotion, configuration: configuration)
                application.search(session)
            case "pending": session.notePendingEditorChanges()
            case "settled":
                if let sequence = body["sequence"] as? NSNumber {
                    session.confirmEditorSequence(
                        sequence.uint64Value, revision: session.documentRevision)
                }
            case "change":
                if let composing = body["composing"] as? Bool { session.setComposing(composing) }
                receiveSource(body)
            case "outline":
                if let raw = body["headings"],
                    let data = try? JSONSerialization.data(withJSONObject: raw),
                    let headings = try? JSONDecoder().decode([DocumentHeading].self, from: data)
                {
                    session.updateOutline(headings, revision: session.documentRevision)
                }
            case "activeHeading": session.observeHeading(body["id"] as? String)
            case "history":
                session.updateHistory(
                    canUndo: body["canUndo"] as? Bool ?? false,
                    canRedo: body["canRedo"] as? Bool ?? false)
            case "search": application.searchState(for: session).receive(body)
            case "composition": session.setComposing(body["composing"] as? Bool ?? false)
            case "notice": session.setEditorNotice(body["message"] as? String)
            case "blur":
                Task { [weak self] in
                    guard let self, !self.session.isClosing else { return }
                    if await self.flush(commitComposition: false) {
                        await self.session.save(.focusLoss)
                    }
                }
            default: break
            }
        }
        private func receiveSource(_ body: [String: Any]) {
            guard let source = body["source"] as? String,
                let sequence = body["sequence"] as? NSNumber,
                let revision = body["revision"] as? NSNumber
            else { return }
            session.receiveEditorSource(
                source, sequence: sequence.uint64Value, revision: revision.uint64Value)
        }
        func flush(commitComposition: Bool) async -> Bool {
            guard !session.editorRecoveryRequired else { return false }
            guard let webView, ready, session.editorReady else {
                if session.hasUnsavedChanges {
                    session.reportEditorFailure()
                    return false
                }
                return true
            }
            let revision = session.documentRevision
            return await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return await window.MyEditor.flush(commit)",
                    arguments: ["commit": commitComposition], in: nil, in: .page
                ) { [weak self] result in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    switch result {
                    case .success(let value):
                        guard let body = value as? [String: Any], body["ok"] as? Bool == true,
                            body["sessionID"] as? String == self.session.id.uuidString,
                            (body["revision"] as? NSNumber)?.uint64Value == revision,
                            revision == self.session.documentRevision
                        else {
                            continuation.resume(returning: false)
                            return
                        }
                        self.session.setComposing(false)
                        self.receiveSource(body)
                        continuation.resume(returning: true)
                    case .failure:
                        self.session.reportEditorFailure()
                        continuation.resume(returning: false)
                    }
                }
            }
        }
        func undo() async { await historyCommand("undo") }
        func redo() async { await historyCommand("redo") }
        private func historyCommand(_ command: String) async {
            guard let webView, session.editorReady, !session.isComposing else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webView.callAsyncJavaScript(
                    "await window.MyEditor[command]()", arguments: ["command": command], in: nil,
                    in: .page
                ) { _ in continuation.resume() }
            }
            if await flush(commitComposition: false) { await session.save(.undoRedo) }
        }
        func setAppearance(_ appearance: String, resolvedDark: Bool) async -> Bool {
            guard let webView, ready, !session.isClosed else { return false }
            return await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return window.MyEditor.setAppearance(appearance, resolvedDark)",
                    arguments: ["appearance": appearance, "resolvedDark": resolvedDark],
                    in: nil,
                    in: .page
                ) { result in
                    guard case .success(let value) = result else {
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: value as? Bool == true)
                }
            }
        }
        func focusDocument() {
            guard let webView else { return }
            webView.window?.makeFirstResponder(webView)
        }
        func navigate(to id: String) {
            guard session.editorReady else { return }
            webView?.callAsyncJavaScript(
                "window.MyEditor.navigate(id)", arguments: ["id": id], in: nil, in: .page,
                completionHandler: nil)
        }
        func search(query: String, requestID: Int, direction: Int?) {
            guard session.editorReady, !session.isClosed else { return }
            var options: [String: Any] = [
                "query": query, "requestID": requestID, "sessionID": session.id.uuidString,
                "revision": session.documentRevision,
            ]
            if let direction { options["direction"] = direction }
            webView?.callAsyncJavaScript(
                "await window.MyEditor.search(options)", arguments: ["options": options], in: nil,
                in: .page
            ) { [weak self] result in
                if case .failure = result, let self {
                    let state = self.application.searchState(for: self.session)
                    if state.requestID == requestID {
                        state.isSearching = false
                        state.message = "搜索暂时不可用，请重试。"
                    }
                }
            }
        }
        func clearSearch(requestID: Int) async -> Bool {
            guard let webView, session.editorReady, !session.isClosed else { return false }
            let revision = session.documentRevision
            let options: [String: Any] = [
                "requestID": requestID, "sessionID": session.id.uuidString, "revision": revision,
            ]
            return await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return window.MyEditor.clearSearch(options)", arguments: ["options": options],
                    in: nil, in: .page
                ) { [weak self] result in
                    guard let self, !self.session.isClosed,
                        self.session.documentRevision == revision,
                        case .success(let value) = result,
                        let body = value as? [String: Any], body["ok"] as? Bool == true,
                        body["cleared"] as? Bool == true,
                        (body["requestID"] as? NSNumber)?.intValue == requestID,
                        body["sessionID"] as? String == self.session.id.uuidString,
                        (body["revision"] as? NSNumber)?.uint64Value == revision
                    else {
                        continuation.resume(returning: false)
                        return
                    }
                    continuation.resume(returning: true)
                }
            }
        }
        func replace(query: String, replacement: String, all: Bool, requestID: Int) async -> Int? {
            guard let webView, session.editorReady, !session.isClosed else { return nil }
            let revision = session.documentRevision
            let options: [String: Any] = [
                "query": query, "replacement": replacement, "all": all, "requestID": requestID,
                "sessionID": session.id.uuidString, "revision": revision,
            ]
            return await withCheckedContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return await window.MyEditor.replace(options)",
                    arguments: ["options": options], in: nil, in: .page
                ) { [weak self] result in
                    guard let self, !self.session.isClosed,
                        self.session.documentRevision == revision,
                        case .success(let value) = result, let body = value as? [String: Any],
                        body["ok"] as? Bool == true
                    else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (body["count"] as? NSNumber)?.intValue ?? 0)
                }
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            loadedRevision = nil
            appliedConfiguration = nil
            session.editorDidTerminate()
        }
        func recover() {
            guard session.editorRecoveryRequired, let html = MarkdownWebEditor.editorHTML,
                let webView
            else { return }
            session.prepareEditorRecovery()
            webView.loadHTMLString(html, baseURL: nil)
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) { session.reportEditorFailure() }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
            } else if url.isFileURL, url.pathExtension.lowercased() == "md" {
                application.open([url])
            }
            decisionHandler(.cancel)
        }

        private func updateWheelMonitor() {
            let needed =
                application.activeDocumentID == session.id && !session.isEditing
                && !session.isClosing && !reduceMotion
            if !needed {
                removeWheelMonitor()
                return
            }
            guard wheelMonitor == nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.filterWheel(event) == nil
                }
                return consumed ? nil : event
            }
            if wheelMonitor != nil { Self.activeWheelMonitors += 1 }
        }
        private func removeWheelMonitor() {
            guard let wheelMonitor else { return }
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
            Self.activeWheelMonitors -= 1
        }
        private func filterWheel(_ event: NSEvent) -> NSEvent? {
            guard let webView, webView.window === event.window, event.window?.isKeyWindow == true,
                NSApp.isActive, session.editorReady, !session.isEditing,
                webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
            else { return event }
            guard !event.hasPreciseScrollingDeltas, event.phase.isEmpty,
                event.momentumPhase.isEmpty,
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else {
                webView.evaluateJavaScript("window.MyEditor.cancelWheel()", completionHandler: nil)
                return event
            }
            webView.callAsyncJavaScript(
                "window.MyEditor.addWheelDelta(delta)",
                arguments: ["delta": -event.scrollingDeltaY * 20], in: nil, in: .page,
                completionHandler: nil)
            return nil
        }

    }
}

/// Keep Markdown-file drops routed to document opening, including over editable content.
final class MarkdownWKWebView: WKWebView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty {
            ApplicationController.shared.isFileDropTargeted = true
            return .copy
        }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty { return .copy }
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        ApplicationController.shared.isFileDropTargeted = false
        super.draggingExited(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty {
            return NativeFileDrop.perform(sender.draggingPasteboard, application: .shared)
        }
        return super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        ApplicationController.shared.isFileDropTargeted = false
        super.concludeDragOperation(sender)
    }
}

@MainActor private final class DocumentImageHandler: NSObject, WKURLSchemeHandler {
    let directory: URL
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(directory: URL) { self.directory = directory }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id]?.cancel()
        let directory = self.directory
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            do {
                guard let requestURL = urlSchemeTask.request.url,
                    let reference = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "path" })?.value,
                    let url = URL(string: reference, relativeTo: directory)?.absoluteURL,
                    url.isFileURL
                else { throw CocoaError(.fileReadInvalidFileName) }
                let read = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: url.standardizedFileURL)
                    try Task.checkCancellation()
                    return data
                }
                let data = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: {
                    read.cancel()
                }
                try Task.checkCancellation()
                let type =
                    UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                urlSchemeTask.didReceive(
                    URLResponse(
                        url: requestURL, mimeType: type, expectedContentLength: data.count,
                        textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
