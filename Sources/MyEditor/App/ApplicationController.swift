import AppKit
import ManuscriptCore
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class ApplicationController {
    static let shared = ApplicationController()
    let store = DocumentStore()
    let preferences = ReaderPreferences()
    let recentDocuments = RecentDocuments()
    @ObservationIgnored private var searches: [UUID: DocumentSearchState] = [:]
    @ObservationIgnored private var searchTasks: [UUID: Task<Void, Never>] = [:]
    var activeDocumentID: UUID?
    var isQuitting = false
    var isFileDropTargeted = false
    @ObservationIgnored private var windows: [UUID: ReaderWindowController] = [:]
    @ObservationIgnored private var editors: [UUID: WeakMarkdownEditor] = [:]
    @ObservationIgnored private var welcome: WelcomeWindowController?
    @ObservationIgnored private var closing: Set<UUID> = []
    @ObservationIgnored private var pickerVisible = false
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceChangeID = 0
    private let logger = Logger(subsystem: "local.novelreader.app", category: "application")

    var activeSession: DocumentSession? { store.sessions.first { $0.id == activeDocumentID } }
    var canUndo: Bool { activeSession?.canUndo ?? false }
    var canRedo: Bool { activeSession?.canRedo ?? false }

    func launch() {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        preferences.applyAppearance()
        if store.sessions.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Application ready")
        #if DEBUG
            if Bundle.main.object(forInfoDictionaryKey: "NRRunEditorChecks") as? Bool == true {
                Task { await EditorIntegrationChecks.run(application: self) }
            }
            if Bundle.main.object(forInfoDictionaryKey: "NRRunDropChecks") as? Bool == true {
                Task { await DropIntegrationChecks.run(application: self) }
            }
            if Bundle.main.object(forInfoDictionaryKey: "NRRunFeatureChecks") as? Bool == true {
                Task { await FeatureIntegrationChecks.run(application: self) }
            }
        #endif
        Task { @MainActor in
            await Task.yield()
            RuntimeDiagnostics.record(
                "window_ready", documents: self.store.sessions.count,
                documentBytes: self.openDocumentBytes)
        }
    }

    func showWelcome() {
        guard !isQuitting, store.sessions.isEmpty else { return }
        if welcome == nil { welcome = WelcomeWindowController(controller: self) }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
        activeDocumentID = nil
    }

    func reopen() {
        if let session = activeSession ?? store.sessions.last {
            windows[session.id]?.window?.makeKeyAndOrderFront(nil)
        } else {
            showWelcome()
        }
    }

    func openPicker() {
        guard !pickerVisible, !isQuitting else { return }
        pickerVisible = true
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文档"
        panel.message = "选择一个或多个 Markdown 文档。"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "打开"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.pickerVisible = false
            if response == .OK { self.open(panel.urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func open(_ urls: [URL]) {
        guard !isQuitting else { return }
        let previous = openingTask
        openingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var failures: [String] = []
            for url in urls {
                guard url.isFileURL, url.pathExtension.lowercased() == "md" else {
                    failures.append("\(url.lastPathComponent)：请选择 .md 文档。")
                    continue
                }
                do {
                    let session = try await self.store.open(url)
                    self.present(session, accessURL: url)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                await self.showError("无法打开部分文档", message: failures.joined(separator: "\n\n"))
            }
        }
    }

    func acceptDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, !isQuitting else { return false }
        RuntimeDiagnostics.record(
            "drop_received_\(urls.count)", documents: store.sessions.count,
            documentBytes: openDocumentBytes)
        open(urls)
        return true
    }

    private func present(_ session: DocumentSession, accessURL: URL) {
        if Bundle.main.object(forInfoDictionaryKey: "NRRunFeatureChecks") as? Bool != true {
            // Preserve the picker/Finder/bookmark URL's grant for future opens.
            recentDocuments.record(accessURL)
        }
        if let existing = windows[session.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            activeDocumentID = session.id
            return
        }
        let host =
            activeDocumentID.flatMap { windows[$0]?.window }
            ?? store.sessions.compactMap { windows[$0.id]?.window }.last
        let controller = ReaderWindowController(session: session, application: self)
        windows[session.id] = controller
        welcome?.close()
        welcome = nil
        guard let window = controller.window else { return }
        if let host { host.addTabbedWindow(window, ordered: .above) }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if window.tabGroup?.isTabBarVisible != true { window.toggleTabBar(nil) }
        activeDocumentID = session.id
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Documents open: \(self.store.sessions.count)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            RuntimeDiagnostics.record(
                "documents_opened", documents: self.store.sessions.count,
                documentBytes: self.openDocumentBytes)
        }
    }

    func activate(_ session: DocumentSession) {
        activeDocumentID = session.id
        retrySearchClear(session)
    }

    func updateWindow(for session: DocumentSession) {
        windows[session.id]?.updateDocumentMetadata()
    }

    func setAppearance(_ appearance: ReaderAppearance) {
        guard preferences.appearance != appearance else { return }
        appearanceChangeID += 1
        let requestID = appearanceChangeID
        let resolvedDark = preferences.resolvedDark(for: appearance)
        let activeEditor = activeSession.flatMap { editor(for: $0) }
        Task { [weak self] in
            if let activeEditor {
                _ = await activeEditor.setAppearance(
                    appearance.rawValue, resolvedDark: resolvedDark)
            }
            guard let self, self.appearanceChangeID == requestID else { return }
            self.preferences.appearance = appearance
        }
    }

    func rename(_ session: DocumentSession, to name: String) async -> String? {
        guard !session.isClosing, !session.isRenaming, !isQuitting else { return "请等待当前文档操作完成。" }
        guard await flushEditor(session) else { return session.issue ?? "请先完成正在输入的文字。" }
        session.setClosing(true)
        defer { session.setClosing(false) }
        guard await flushEditor(session) else { return session.issue ?? "正文尚未同步，请稍后重试。" }
        do {
            let previousURL = session.url
            try await session.rename(to: name)
            recentDocuments.record(session.url, replacing: previousURL)
            updateWindow(for: session)
            return nil
        } catch { return error.localizedDescription }
    }

    func registerEditor(_ editor: any MarkdownEditorControlling, for session: DocumentSession) {
        editors[session.id] = WeakMarkdownEditor(editor)
    }
    func unregisterEditor(for session: DocumentSession) { editors.removeValue(forKey: session.id) }
    func editor(for session: DocumentSession) -> (any MarkdownEditorControlling)? {
        editors[session.id]?.value
    }

    func searchState(for session: DocumentSession) -> DocumentSearchState {
        if let state = searches[session.id] { return state }
        let state = DocumentSearchState()
        searches[session.id] = state
        return state
    }

    func focusSearch(replace: Bool = false) {
        guard let session = activeSession else { return }
        let state = searchState(for: session)
        state.mode = replace ? .replace : .find
        state.showsReplacement = replace
        state.focusRequest += 1
    }

    func search(_ session: DocumentSession) {
        let state = searchState(for: session)
        if state.query.isEmpty {
            endSearch(session)
            return
        }
        let request = state.nextRequest()
        searchTasks[session.id]?.cancel()
        searchTasks[session.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard let self, !Task.isCancelled, state.requestID == request, !session.isClosed else {
                return
            }
            self.editor(for: session)?.search(
                query: state.query, requestID: request, direction: nil)
        }
    }

    func endSearch(_ session: DocumentSession, returnToDocument: Bool = false) {
        let state = searchState(for: session)
        state.endSearch()
        searchTasks.removeValue(forKey: session.id)?.cancel()
        retrySearchClear(session)
        if returnToDocument {
            state.isFocused = false
            editor(for: session)?.focusDocument()
        }
    }

    func retrySearchClear(_ session: DocumentSession) {
        let state = searchState(for: session)
        guard let request = state.pendingClearID, session.editorReady else { return }
        searchTasks.removeValue(forKey: session.id)?.cancel()
        searchTasks[session.id] = Task { [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(100 * attempt)) } catch { return }
                }
                guard let self, !Task.isCancelled, !session.isClosed,
                    state.requestID == request, state.query.isEmpty
                else { return }
                if await self.editor(for: session)?.clearSearch(requestID: request) == true {
                    state.acknowledgeClear(request)
                    return
                }
            }
            // Retain the request for the next editor-ready/window activation.
        }
    }

    func findNext(_ session: DocumentSession, by direction: Int) {
        let state = searchState(for: session)
        guard !state.query.isEmpty, !state.isReplacing else { return }
        searchTasks[session.id]?.cancel()
        editor(for: session)?.search(
            query: state.query, requestID: state.requestID, direction: direction)
    }

    func replace(_ session: DocumentSession, all: Bool) {
        let state = searchState(for: session)
        guard state.canReplace, session.editorReady, !session.isClosing, !session.isRenaming,
            !session.showsSource
        else {
            return
        }
        state.isReplacing = true
        let request = state.requestID
        let query = state.query
        let replacement = state.replacement
        Task { [weak self] in
            defer { state.isReplacing = false }
            guard let self, await self.flushEditor(session), !session.isClosed,
                state.requestID == request, state.query == query
            else { return }
            guard
                let count = await self.editor(for: session)?.replace(
                    query: query, replacement: replacement, all: all, requestID: request)
            else {
                state.message = "内容已变化，请重新查找后替换。"
                return
            }
            if count > 0 { session.beginEditing() }
            state.message = count > 0 ? "已替换 \(count) 处" : "没有需要替换的内容"
        }
    }

    func openRecent(_ entry: RecentDocuments.Entry) {
        Task {
            let url = await recentDocuments.resolve(entry)
            if url != entry.url { recentDocuments.record(url, replacing: entry.url) }
            open([url])
        }
    }

    func revealInFinder(_ session: DocumentSession) {
        let url = session.url
        Task {
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: url.path)
            }.value
            guard !session.isClosed else { return }
            if exists {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                await showError("无法在访达中定位", message: "文件可能已被移动或删除：\n\(url.path)")
            }
        }
    }

    @discardableResult func flushEditor(_ session: DocumentSession, commitComposition: Bool = true)
        async -> Bool
    {
        if let editor = editor(for: session) {
            return await editor.flush(commitComposition: commitComposition)
        }
        if session.editorHasPendingChanges {
            session.reportEditorFailure()
            return false
        }
        return !session.isComposing
    }
    @discardableResult func save(
        _ session: DocumentSession, reason: SaveReason, commitComposition: Bool = true
    ) async -> Bool {
        guard await flushEditor(session, commitComposition: commitComposition) else { return false }
        return await session.save(reason)
    }

    #if DEBUG
        func validationWindow(for session: DocumentSession) -> NSWindow? {
            windows[session.id]?.window
        }
        func validationController(for session: DocumentSession) -> ReaderWindowController? {
            windows[session.id]
        }
        func waitForValidationOpen() async { await openingTask?.value }
    #endif

    func saveActive() {
        guard let session = activeSession else { return }
        Task { await save(session, reason: .explicit, commitComposition: false) }
    }
    func undo() {
        guard let session = activeSession, session.canUndo else { return }
        session.beginEditing()
        Task { await editor(for: session)?.undo() }
    }
    func redo() {
        guard let session = activeSession, session.canRedo else { return }
        session.beginEditing()
        Task { await editor(for: session)?.redo() }
    }
    func navigate(_ session: DocumentSession, to id: String) {
        guard !session.isClosing else { return }
        Task {
            guard await flushEditor(session) else { return }
            session.observeHeading(id)
            editor(for: session)?.navigate(to: id)
            await session.save(.navigation)
        }
    }
    func navigateRelative(_ session: DocumentSession, by delta: Int) {
        let headings = session.primaryHeadings
        let index = headings.firstIndex { $0.id == session.activePrimaryID } ?? 0
        guard headings.indices.contains(index + delta) else { return }
        navigate(session, to: headings[index + delta].id)
    }
    func toggleEditing(_ session: DocumentSession) {
        guard !session.isClosing, session.editorReady else { return }
        session.showsSource = false
        if session.isEditing {
            Task {
                guard await flushEditor(session) else { return }
                session.setClosing(true)
                defer { session.setClosing(false) }
                guard await flushEditor(session) else { return }
                await session.finishEditing()
            }
        } else {
            session.beginEditing()
        }
    }
    func requestClose(_ session: DocumentSession) {
        guard !closing.contains(session.id), !isQuitting else { return }
        closing.insert(session.id)
        Task {
            _ = await flushEditor(session)
            session.setClosing(true)
            if await ensureSaved(session) { closeSaved(session) }
            session.setClosing(false)
            closing.remove(session.id)
        }
    }

    func closeKeyWindow() {
        guard let keyWindow = NSApp.keyWindow else { return }
        if let session = store.sessions.first(where: { windows[$0.id]?.window === keyWindow }) {
            requestClose(session)
        } else {
            keyWindow.performClose(nil)
        }
    }

    private func ensureSaved(_ session: DocumentSession) async -> Bool {
        while !session.isClosed {
            if await save(session, reason: .close) {
                if !session.hasUnsavedChanges && !session.isComposing { return true }
                continue
            }
            windows[session.id]?.window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(session.url.lastPathComponent)”尚未保存"
            alert.informativeText = (session.issue ?? "请先完成输入。") + "\n文档将保持打开，直到保存成功或另存副本。"
            alert.addButton(withTitle: session.editorRecoveryRequired ? "恢复最近同步的正文" : "重试")
            alert.addButton(withTitle: "另存副本…")
            alert.addButton(withTitle: "取消关闭")
            alert.buttons[2].keyEquivalent = "\u{1b}"
            let response = await show(alert, window: windows[session.id]?.window)
            if response == .alertSecondButtonReturn { return await saveCopy(session) }
            if response != .alertFirstButtonReturn { return false }
            if session.editorRecoveryRequired {
                editor(for: session)?.recover()
                return false
            }
        }
        return true
    }

    private func closeSaved(_ session: DocumentSession) {
        guard let controller = windows.removeValue(forKey: session.id) else { return }
        searchTasks.removeValue(forKey: session.id)?.cancel()
        searches.removeValue(forKey: session.id)
        controller.permitClose = true
        store.close(session)
        controller.close()
        if activeDocumentID == session.id { activeDocumentID = store.sessions.last?.id }
        logger.info("Documents remaining: \(self.store.sessions.count)")
        if store.sessions.isEmpty && !isQuitting { showWelcome() }
        Task { @MainActor [weak session, weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            RuntimeDiagnostics.record(
                "document_closed", documents: self.store.sessions.count,
                documentBytes: self.openDocumentBytes, released: session == nil)
        }
    }

    private var openDocumentBytes: Int {
        store.sessions.reduce(0) { $0 + $1.savedSnapshot.source.utf8.count }
    }

    func terminate() -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        Task {
            for session in store.sessions {
                _ = await flushEditor(session)
                session.setClosing(true)
            }
            for session in store.sessions {
                if !(await ensureSaved(session)) {
                    isQuitting = false
                    for opened in store.sessions { opened.setClosing(false) }
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            for session in store.sessions { closeSaved(session) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @discardableResult func saveCopy(_ session: DocumentSession) async -> Bool {
        if !session.editorRecoveryRequired {
            guard await flushEditor(session) else { return false }
        }
        let panel = NSSavePanel()
        panel.title = session.editorRecoveryRequired ? "导出最近同步的正文" : "另存为 Markdown 文档"
        if session.editorRecoveryRequired { panel.message = "副本包含最近同步的正文，可能不包含中断前最后的输入。源文件保持不变。" }
        panel.nameFieldStringValue =
            session.url.deletingPathExtension().lastPathComponent + "-副本.md"
        panel.directoryURL = session.url.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = windows[session.id]?.window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let url = panel.url else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical != session.url else {
            await showError("请选择不同的文件名", message: "另存为需要一个新路径，以保留源文件和当前草稿。")
            return false
        }
        do {
            if !session.editorRecoveryRequired {
                guard await flushEditor(session) else { return false }
            }
            if session.editorRecoveryRequired {
                _ = try await session.writeRecoveryCopy(to: url)
            } else {
                _ = try await session.writeCopy(to: url)
            }
            if !isQuitting {
                let copy = try await store.open(url)
                present(copy, accessURL: url)
            }
            return true
        } catch {
            await showError("无法保存副本", message: error.localizedDescription)
            return false
        }
    }

    func loadExternal(_ session: DocumentSession) {
        Task {
            guard await flushEditor(session) else { return }
            session.setClosing(true)
            defer { session.setClosing(false) }
            guard await flushEditor(session) else { return }
            await session.loadExternalVersion()
        }
    }

    func showError(_ title: String, message: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = await show(alert, window: NSApp.keyWindow)
    }

    private func show(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }
}
