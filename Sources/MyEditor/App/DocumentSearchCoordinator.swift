import Foundation
import ManuscriptCore

/// Find and replace for every open document. Each document keeps its own
/// state; requests are debounced, and replies for an older request are ignored.
@MainActor final class DocumentSearchCoordinator {
    unowned let application: ApplicationController
    private var states: [UUID: DocumentSearchState] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(application: ApplicationController) { self.application = application }

    func state(for session: DocumentSession) -> DocumentSearchState {
        if let state = states[session.id] { return state }
        let state = DocumentSearchState()
        states[session.id] = state
        return state
    }

    func focus(replace: Bool = false) {
        guard let session = application.activeSession else { return }
        let state = state(for: session)
        state.mode = replace ? .replace : .find
        state.showsReplacement = replace
        state.focusRequest += 1
    }

    func search(_ session: DocumentSession) {
        let state = state(for: session)
        if state.query.isEmpty {
            end(session)
            return
        }
        let request = state.nextRequest()
        tasks[session.id]?.cancel()
        tasks[session.id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            guard let self, !Task.isCancelled, state.requestID == request, !session.isClosed else {
                return
            }
            self.application.editor(for: session)?.search(
                query: state.query, requestID: request, direction: nil)
        }
    }

    func end(_ session: DocumentSession, returnToDocument: Bool = false) {
        let state = state(for: session)
        state.endSearch()
        tasks.removeValue(forKey: session.id)?.cancel()
        retryClear(session)
        if returnToDocument {
            state.isFocused = false
            application.editor(for: session)?.focusDocument()
        }
    }

    func retryClear(_ session: DocumentSession) {
        let state = state(for: session)
        guard let request = state.pendingClearID, session.editorReady else { return }
        tasks.removeValue(forKey: session.id)?.cancel()
        tasks[session.id] = Task { [weak self] in
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(100 * attempt)) } catch { return }
                }
                guard let self, !Task.isCancelled, !session.isClosed,
                    state.requestID == request, state.query.isEmpty
                else { return }
                if await self.application.editor(for: session)?.clearSearch(requestID: request)
                    == true
                {
                    state.acknowledgeClear(request)
                    return
                }
            }
            // Retain the request for the next editor-ready/window activation.
        }
    }

    func findNext(_ session: DocumentSession, by direction: Int) {
        let state = state(for: session)
        guard !state.query.isEmpty, !state.isReplacing else { return }
        tasks[session.id]?.cancel()
        application.editor(for: session)?.search(
            query: state.query, requestID: state.requestID, direction: direction)
    }

    func replace(_ session: DocumentSession, all: Bool) {
        let state = state(for: session)
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
            guard let self, await self.application.flushEditor(session), !session.isClosed,
                state.requestID == request, state.query == query
            else { return }
            guard
                let count = await self.application.editor(for: session)?.replace(
                    query: query, replacement: replacement, all: all, requestID: request)
            else {
                state.message = "内容已变化，请重新查找后替换。"
                return
            }
            if count > 0 { session.beginEditing() }
            state.message = count > 0 ? "已替换 \(count) 处" : "没有需要替换的内容"
        }
    }

    func forget(_ session: DocumentSession) {
        tasks.removeValue(forKey: session.id)?.cancel()
        states.removeValue(forKey: session.id)
    }
}
