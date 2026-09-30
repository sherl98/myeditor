import AppKit
import ManuscriptCore
import UniformTypeIdentifiers

enum NewDocumentSaveResult { case saved, discarded, cancelled }

/// Saving, first saves of new documents, copies, and the prompts around them.
extension ApplicationController {
    @discardableResult func save(
        _ session: DocumentSession, reason: SaveReason, commitComposition: Bool = true
    ) async -> Bool {
        if session.isUntitled, reason == .explicit {
            return await saveNewDocument(session, closing: false) == .saved
        }
        guard await flushEditor(session, commitComposition: commitComposition) else { return false }
        return await session.save(reason)
    }

    func saveActive() {
        guard let session = activeSession else { return }
        Task { await save(session, reason: .explicit, commitComposition: false) }
    }
    func ensureSaved(_ session: DocumentSession) async -> Bool {
        if session.isUntitled {
            let result = await saveNewDocument(session, closing: true)
            if result == .discarded {
                closeSaved(session)
                return true
            }
            return result == .saved
        }
        while !session.isClosed {
            if await save(session, reason: .close) {
                if !session.hasUnsavedChanges && !session.isComposing { return true }
                continue
            }
            windows[session.id]?.window?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(session.displayName)”尚未保存"
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

    @discardableResult func saveCopy(_ session: DocumentSession) async -> Bool {
        if session.isUntitled, !session.editorRecoveryRequired {
            return await saveNewDocument(session, closing: false) == .saved
        }
        if !session.editorRecoveryRequired {
            guard await flushEditor(session) else { return false }
        }
        let panel = NSSavePanel()
        panel.title = session.editorRecoveryRequired ? "导出最近同步的正文" : "另存为 Markdown 文档"
        if session.editorRecoveryRequired { panel.message = "副本包含最近同步的正文，可能不包含中断前最后的输入。源文件保持不变。" }
        panel.nameFieldStringValue =
            session.suggestedName + "-副本.md"
        panel.directoryURL = session.url?.deletingLastPathComponent()
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

    private func saveNewDocument(_ session: DocumentSession, closing: Bool) async
        -> NewDocumentSaveResult
    {
        guard !session.isClosed, !savingDocuments.contains(session.id) else { return .cancelled }
        savingDocuments.insert(session.id)
        let wasClosing = session.isClosing
        // Commit input before making the document read-only. Deleting remains available if flush fails.
        _ = await flushEditor(session)
        session.setClosing(true)
        defer {
            session.setClosing(wasClosing)
            savingDocuments.remove(session.id)
        }
        if closing {
            let confirmation = NewDocumentCloseConfirmation(
                name: session.suggestedName, window: windows[session.id]?.window
            ) { [self] destination in
                guard await flushEditor(session) else {
                    throw NSError(
                        domain: "MyEditor", code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: session.issue ?? "请先完成正在输入的文字，然后重试保存。"
                        ])
                }
                try await store.saveFirst(session, to: destination)
                recentDocuments.record(destination)
                updateWindow(for: session)
            }
            switch await confirmation.confirm() {
            case .saved: return .saved
            case .discarded: return .discarded
            case .cancelled: return .cancelled
            }
        }
        let panel = NSSavePanel()
        panel.title = "保存 Markdown 文稿"
        panel.message = "选择文件名和位置。保存后将自动保存后续修改。"
        panel.nameFieldStringValue = session.suggestedName + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "保存"
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = windows[session.id]?.window {
                window.makeKeyAndOrderFront(nil)
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let destination = panel.url else { return .cancelled }
        guard await flushEditor(session) else {
            await showError("文稿尚未保存", message: session.issue ?? "请先完成正在输入的文字，然后重试保存。")
            return .cancelled
        }
        do {
            try await store.saveFirst(session, to: destination)
            recentDocuments.record(destination)
            updateWindow(for: session)
            return .saved
        } catch {
            await showError("无法保存文稿", message: error.localizedDescription)
            return .cancelled
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
