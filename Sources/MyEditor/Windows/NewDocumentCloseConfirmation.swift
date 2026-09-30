import AppKit
import UniformTypeIdentifiers

/// A short-lived bridge to AppKit's native “keep this new document” sheet.
/// DocumentSession remains the owner of the contents, file writes and autosaving.
@MainActor
final class NewDocumentCloseConfirmation: NSDocument {
    enum Result { case saved, discarded, cancelled }

    private weak var parentWindow: NSWindow?
    private let suggestedName: String
    private let saveHandler: @MainActor (URL) async throws -> Void
    private var continuation: CheckedContinuation<Result, Never>?
    private var didSave = false

    init(
        name: String, window: NSWindow?,
        save: @escaping @MainActor (URL) async throws -> Void
    ) {
        suggestedName = name
        parentWindow = window
        saveHandler = save
        super.init()
        fileType = "net.daringfireball.markdown"
        displayName = name
        hasUndoManager = false
        // Empty new documents must also ask whether to keep or delete them.
        updateChangeCount(.changeDone)
    }

    override class var autosavesInPlace: Bool { true }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }
    override class var writableTypes: [String] { ["net.daringfireball.markdown"] }
    override class func isNativeType(_ type: String) -> Bool {
        type == "net.daringfireball.markdown"
    }
    override var windowForSheet: NSWindow? { parentWindow }

    // Opt into the native confirmation UI without starting an NSDocument autosave
    // lifecycle. Only an explicit Save in the sheet may invoke the session writer.
    override func scheduleAutosaving() {}
    override func autosave(
        withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.nameFieldStringValue = suggestedName + ".md"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        savePanel.allowsOtherFileTypes = false
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        // Leave the native heading, explanatory text and Delete button untouched.
        return true
    }

    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard saveOperation == .saveOperation || saveOperation == .saveAsOperation else {
            completionHandler(CocoaError(.userCancelled))
            return
        }
        Task {
            do {
                try await saveHandler(url)
                didSave = true
                updateChangeCount(.changeCleared)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func confirm() async -> Result {
        parentWindow?.makeKeyAndOrderFront(nil)
        let result: Result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            canClose(
                withDelegate: self,
                shouldClose: #selector(didConfirm(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        // No window controllers are attached: close only releases AppKit's document
        // bookkeeping, never the application's editor or window.
        close()
        return result
    }

    @objc private func didConfirm(
        _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        let result: Result = shouldClose ? (didSave ? .saved : .discarded) : .cancelled
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}
