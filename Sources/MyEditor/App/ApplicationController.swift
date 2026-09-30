import AppKit
import ManuscriptCore
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class ApplicationController {
    static let shared: ApplicationController = {
        // Before any setting is read: bring over preferences of earlier builds.
        if Bundle.main.bundleIdentifier == "io.github.sherl98.myeditor" {
            LegacyPreferences.migrate(
                from: UserDefaults.standard.persistentDomain(
                    forName: LegacyPreferences.legacyDomain),
                into: UserDefaults.standard)
        }
        return ApplicationController()
    }()
    let store = DocumentStore()
    let preferences = ReaderPreferences()
    let recentDocuments = RecentDocuments()
    @ObservationIgnored private(set) lazy var searching = DocumentSearchCoordinator(
        application: self)
    /// Documents whose network images the user chose to load, and how many
    /// images each document is currently holding back.
    private var remoteImageDocuments: Set<UUID> = []
    private(set) var blockedRemoteImages: [UUID: Int] = [:]
    var activeDocumentID: UUID?
    var isQuitting = false
    var isFileDropTargeted = false
    /// A native text field (search, replace, rename) owns the keyboard, so Edit
    /// menu commands belong to it rather than to the document.
    private(set) var nativeTextFocused = false
    @ObservationIgnored private var windowUpdateObserver: (any NSObjectProtocol)?
    @ObservationIgnored var windows: [UUID: ReaderWindowController] = [:]
    @ObservationIgnored private var editors: [UUID: WeakMarkdownEditor] = [:]
    @ObservationIgnored private var welcome: WelcomeWindowController?
    @ObservationIgnored private var closing: Set<UUID> = []
    @ObservationIgnored private var openPanel: NSOpenPanel?
    @ObservationIgnored private var createAfterPicker = false
    @ObservationIgnored var savingDocuments: Set<UUID> = []
    @ObservationIgnored private var openingTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceChangeID = 0
    private let logger = Logger(subsystem: "io.github.sherl98.myeditor", category: "application")

    var activeSession: DocumentSession? { store.sessions.first { $0.id == activeDocumentID } }
    var canUndo: Bool { activeSession?.canUndo ?? false }
    var canRedo: Bool { activeSession?.canRedo ?? false }
    private static var nativeTextResponder: NSText? { NSApp.keyWindow?.firstResponder as? NSText }

    func launch() {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = true
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        preferences.applyAppearance()
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let focused = Self.nativeTextResponder != nil
                if self.nativeTextFocused != focused { self.nativeTextFocused = focused }
            }
        }
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
        guard openPanel == nil, !isQuitting else { return }
        let panel = DocumentOpenPanel.make()
        openPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            panel.orderOut(nil)
            if self.createAfterPicker {
                self.createAfterPicker = false
                self.newDocument()
            } else if response == .OK {
                self.open(panel.urls)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func newDocument() {
        guard !isQuitting else { return }
        if let panel = openPanel {
            createAfterPicker = true
            panel.cancel(nil)
            return
        }
        present(store.createDocument(), accessURL: nil)
    }

    func open(_ urls: [URL]) {
        guard !isQuitting else { return }
        let previous = openingTask
        openingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var failures: [String] = []
            for url in urls {
                guard ManuscriptCodec.isMarkdownFile(url) else {
                    failures.append("\(url.lastPathComponent)：请选择 Markdown 文档（.md、.markdown 等）。")
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
                // Report without holding the open queue: later drops still open.
                let message = failures.joined(separator: "\n\n")
                Task { await self.showError("无法打开部分文档", message: message) }
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

    func present(_ session: DocumentSession, accessURL: URL?) {
        var recordsRecent = accessURL != nil
        #if DEBUG
            // Validation fixtures stay out of the recent documents list.
            if Bundle.main.object(forInfoDictionaryKey: "NRRunFeatureChecks") as? Bool == true {
                recordsRecent = false
            }
        #endif
        if recordsRecent, let accessURL {
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
        searching.retryClear(session)
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
        let result: String?? = await withEditorLocked(session) {
            do {
                let previousURL = session.url
                try await session.rename(to: name)
                if let url = session.url { recentDocuments.record(url, replacing: previousURL) }
                updateWindow(for: session)
                return nil
            } catch { return error.localizedDescription }
        }
        return result ?? (session.issue ?? "请先完成正在输入的文字，然后重试。")
    }

    /// Commits pending input, makes the page read-only, and commits again so no
    /// keystroke lands between the last flush and `body`. Nil if input is pending.
    @discardableResult
    func withEditorLocked<T>(_ session: DocumentSession, _ body: () async -> T) async -> T? {
        guard await flushEditor(session) else { return nil }
        session.setClosing(true)
        defer { session.setClosing(false) }
        guard await flushEditor(session) else { return nil }
        return await body()
    }

    func loadsRemoteImages(_ session: DocumentSession) -> Bool {
        preferences.loadRemoteImages || remoteImageDocuments.contains(session.id)
    }
    func allowRemoteImages(_ session: DocumentSession) {
        remoteImageDocuments.insert(session.id)
        blockedRemoteImages[session.id] = nil
    }
    func noteBlockedRemoteImages(_ count: Int, in session: DocumentSession) {
        let value = count > 0 && !loadsRemoteImages(session) ? count : nil
        if blockedRemoteImages[session.id] != value { blockedRemoteImages[session.id] = value }
    }

    func registerEditor(_ editor: any MarkdownEditorControlling, for session: DocumentSession) {
        editors[session.id] = WeakMarkdownEditor(editor)
    }
    func unregisterEditor(for session: DocumentSession) { editors.removeValue(forKey: session.id) }
    func editor(for session: DocumentSession) -> (any MarkdownEditorControlling)? {
        editors[session.id]?.value
    }

    func openRecent(_ entry: RecentDocuments.Entry) {
        Task {
            let url = await recentDocuments.resolve(entry)
            if url != entry.url { recentDocuments.record(url, replacing: entry.url) }
            open([url])
        }
    }

    func revealInFinder(_ session: DocumentSession) {
        guard let url = session.url else { return }
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
    #if DEBUG
        func validationWindow(for session: DocumentSession) -> NSWindow? {
            windows[session.id]?.window
        }
        func validationController(for session: DocumentSession) -> ReaderWindowController? {
            windows[session.id]
        }
        func waitForValidationOpen() async { await openingTask?.value }
    #endif

    /// ⌘Z: native text fields keep AppKit's own undo; the document uses the editor's.
    func performUndo() {
        if Self.nativeTextResponder != nil {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
            undo()
        }
    }
    func performRedo() {
        if Self.nativeTextResponder != nil {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else {
            redo()
        }
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
            Task { await withEditorLocked(session) { await session.finishEditing() } }
        } else {
            session.beginEditing()
        }
    }
    func requestClose(_ session: DocumentSession) {
        guard !closing.contains(session.id), !savingDocuments.contains(session.id), !isQuitting
        else { return }
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

    func closeSaved(_ session: DocumentSession) {
        guard let controller = windows.removeValue(forKey: session.id) else { return }
        searching.forget(session)
        remoteImageDocuments.remove(session.id)
        blockedRemoteImages[session.id] = nil
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
        guard savingDocuments.isEmpty, closing.isEmpty, openPanel == nil else {
            return .terminateCancel
        }
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

    func loadExternal(_ session: DocumentSession) {
        Task { await withEditorLocked(session) { await session.loadExternalVersion() } }
    }

}
