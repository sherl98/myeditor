import Foundation
import OSLog
import Observation

public enum SaveReason: Sendable {
    case idle, explicit, focusLoss, navigation, done, undoRedo, close, composition
}

@Observable @MainActor
public final class DocumentSession: Identifiable {
    public let id = UUID()
    public private(set) var url: URL
    public private(set) var savedSnapshot: FileSnapshot
    public private(set) var draftSource: String?
    public private(set) var outline: [DocumentHeading] = []
    public private(set) var generation: UInt64 = 0
    public private(set) var savedGeneration: UInt64 = 0
    /// Only external reloads replace the editor document; saving never does.
    public private(set) var documentRevision: UInt64 = 0
    public var showsSource = false
    public private(set) var isEditing = false
    public private(set) var isSaving = false
    public private(set) var isRenaming = false
    public private(set) var isComposing = false
    public private(set) var isClosed = false
    public private(set) var isClosing = false
    public private(set) var editorRecoveryRequired = false
    private var confirmedEditorSource: String
    private var recoverySource: String?
    public private(set) var editorReady = false
    public private(set) var editorHasPendingChanges = false
    public private(set) var issue: String?
    public private(set) var editorNotice: String?
    public private(set) var hasConflict = false
    public private(set) var keptConflictingDraft = false
    public private(set) var externalReloadCount = 0
    public private(set) var successfulSaveCount = 0
    public private(set) var activeHeadingID: String?
    public private(set) var lastSavedAt: Date?
    private var editorHasChangedDocument = false
    private var editorCanUndo = false
    private var editorCanRedo = false
    @ObservationIgnored private var lastEditorSequence: UInt64 = 0
    @ObservationIgnored public var prepareForExternalReload: (@MainActor () async -> Bool)?
    @ObservationIgnored private let files: any DocumentFileAccess
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Bool, Never>?
    @ObservationIgnored private var renameTask: Task<Void, Error>?
    @ObservationIgnored private var externalTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DocumentWatcher?
    @ObservationIgnored private var pendingExternalCheck = false
    @ObservationIgnored private var fileUnavailable = false
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private let watchesFile: Bool
    @ObservationIgnored private var conflictRevision: String?
    private static let logger = Logger(subsystem: "local.novelreader.app", category: "documents")

    public init(
        url: URL, snapshot: FileSnapshot, files: any DocumentFileAccess = DiskFileAccess(),
        watch: Bool = true, accessURL: URL? = nil
    ) throws {
        self.confirmedEditorSource = ManuscriptCodec.editorSource(snapshot.source)
        self.url = url
        self.savedSnapshot = snapshot
        self.files = files
        self.watchesFile = watch
        let accessURL = accessURL ?? url
        if accessURL.startAccessingSecurityScopedResource() { securityScopedURL = accessURL }
        restartWatcher()
    }

    public var source: String { draftSource ?? ManuscriptCodec.editorSource(savedSnapshot.source) }
    public var title: String {
        outline.first(where: { $0.level == 1 })?.title
            ?? url.deletingPathExtension().lastPathComponent
    }
    public var primaryHeadings: [DocumentHeading] { ManuscriptCodec.primaryHeadings(outline) }
    public var activeHeadingIndex: Int { outline.firstIndex { $0.id == activeHeadingID } ?? 0 }
    public var activePrimaryID: String? {
        let index = activeHeadingIndex
        return primaryHeadings.last { item in
            (outline.firstIndex { $0.id == item.id } ?? 0) <= index
        }?.id ?? primaryHeadings.first?.id
    }
    public var hasUnsavedChanges: Bool { draftSource != nil || editorHasPendingChanges }
    public var canUndo: Bool {
        editorHasChangedDocument && editorCanUndo && !isClosed && !isClosing && !isComposing
            && editorReady
    }
    public var canRedo: Bool {
        editorHasChangedDocument && editorCanRedo && !isClosed && !isClosing && !isComposing
            && editorReady
    }
    public var statusText: String {
        if hasConflict { return keptConflictingDraft ? "草稿已保留 · 写回暂停" : "源文件有新版本" }
        if let issue { return issue }
        if isComposing { return "正在输入…" }
        if isRenaming { return "正在重命名…" }
        if isSaving { return "正在保存…" }
        if hasUnsavedChanges { return "尚未保存" }
        if let editorNotice { return editorNotice }
        return "已同步到源文件"
    }

    /// Freeze the last confirmed source. Late messages from the dead page are rejected.
    public func editorDidTerminate() {
        guard !isClosed, !editorRecoveryRequired else { return }
        recoverySource = isComposing ? confirmedEditorSource : source
        editorRecoveryRequired = true
        editorReady = false
        editorHasPendingChanges = false
        isComposing = false
        autoSaveTask?.cancel()
        generation += 1
        documentRevision += 1
        lastEditorSequence = 0
        updateHistory(canUndo: false, canRedo: false)
        issue = "编辑器意外中断，已保留最近同步的正文；最后尚未同步的输入可能未包含在内。"
    }

    /// Called only by the user's explicit recovery action; never writes the original.
    public func prepareEditorRecovery() {
        guard editorRecoveryRequired, let recoverySource else { return }
        draftSource =
            recoverySource == ManuscriptCodec.editorSource(savedSnapshot.source)
            ? nil : recoverySource
        confirmedEditorSource = recoverySource
        self.recoverySource = nil
        editorRecoveryRequired = false
        editorHasChangedDocument = false
        issue = nil
        editorNotice = "已恢复最近同步的正文"
    }

    public func writeRecoveryCopy(to destination: URL) async throws -> FileSnapshot {
        guard editorRecoveryRequired, let recoverySource else {
            throw ManuscriptError.editorUnavailable
        }
        guard
            destination.standardizedFileURL.resolvingSymlinksInPath()
                != url.standardizedFileURL.resolvingSymlinksInPath()
        else { throw ManuscriptError.invalidName }
        return try await files.writeCopy(
            destination,
            source: ManuscriptCodec.encodedSource(recoverySource, matching: savedSnapshot.source))
    }

    public func setEditorReady(_ ready: Bool) { editorReady = ready }
    public func setEditorNotice(_ notice: String?) { editorNotice = notice }
    public func reportEditorFailure() {
        guard !editorRecoveryRequired else { return }
        issue = ManuscriptError.editorUnavailable.localizedDescription
    }
    public func notePendingEditorChanges() { if !isClosed { editorHasPendingChanges = true } }
    public func updateHistory(canUndo: Bool, canRedo: Bool) {
        editorCanUndo = canUndo
        editorCanRedo = canRedo
    }
    public func updateOutline(_ headings: [DocumentHeading], revision: UInt64) {
        guard revision == documentRevision, !isClosed else { return }
        let previousIndex = activeHeadingIndex
        if outline != headings { outline = headings }
        if !headings.contains(where: { $0.id == activeHeadingID }) {
            activeHeadingID =
                headings.isEmpty ? nil : headings[min(previousIndex, headings.count - 1)].id
        }
    }
    public func observeHeading(_ id: String?) {
        guard let id, outline.contains(where: { $0.id == id }), activeHeadingID != id else {
            return
        }
        activeHeadingID = id
    }
    public func beginEditing() {
        guard !isClosed, !isClosing, editorReady else { return }
        isEditing = true
    }
    @discardableResult public func finishEditing() async -> Bool {
        guard await save(.done) else { return false }
        isEditing = false
        return true
    }
    public func setClosing(_ closing: Bool) { if !isClosed { isClosing = closing } }

    /// Revision and sequence reject delayed messages from an earlier editor load.
    public func receiveEditorSource(_ text: String, sequence: UInt64, revision: UInt64) {
        guard !isClosed, !editorRecoveryRequired, revision == documentRevision,
            sequence >= lastEditorSequence
        else {
            return
        }
        if sequence == lastEditorSequence {
            editorHasPendingChanges = false
            return
        }
        if !isComposing { confirmedEditorSource = text }
        lastEditorSequence = sequence
        editorHasPendingChanges = false
        guard source != text else { return }
        editorHasChangedDocument = true
        generation += 1
        draftSource =
            !isSaving && text == ManuscriptCodec.editorSource(savedSnapshot.source) ? nil : text
        if draftSource == nil { savedGeneration = generation }
        if !fileUnavailable && !hasConflict { issue = nil }
        scheduleAutoSave()
    }
    public func confirmEditorSequence(_ sequence: UInt64, revision: UInt64) {
        guard !isClosed, !editorRecoveryRequired, !isComposing,
            revision == documentRevision, sequence == lastEditorSequence
        else { return }
        editorHasPendingChanges = false
    }

    public func setComposing(_ composing: Bool) {
        guard !isClosed else { return }
        isComposing = composing
        if !composing { confirmedEditorSource = source }
        if composing {
            autoSaveTask?.cancel()
            autoSaveTask = nil
        } else {
            scheduleAutoSave()
        }
    }
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        guard !isComposing, !hasConflict, !isClosing, !isRenaming, draftSource != nil else {
            return
        }
        autoSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.autoSaveTask = nil
            await self.save(.idle)
        }
    }
    public func serializedSource() -> String {
        guard let draftSource else { return savedSnapshot.source }
        return ManuscriptCodec.encodedSource(draftSource, matching: savedSnapshot.source)
    }

    @discardableResult public func save(_ reason: SaveReason) async -> Bool {
        if let renameTask {
            do { try await renameTask.value } catch { return false }
        }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        guard !isClosed, !editorRecoveryRequired, !isComposing, !hasConflict,
            !editorHasPendingChanges
        else { return false }
        if let saveTask { return await saveTask.value }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            self.isSaving = true
            defer {
                self.isSaving = false
                self.saveTask = nil
                if self.pendingExternalCheck {
                    self.pendingExternalCheck = false
                    self.scheduleExternalCheck()
                }
            }
            return await self.drainSaves()
        }
        saveTask = task
        return await task.value
    }

    public func rename(to proposedName: String) async throws {
        guard !isClosed else { throw ManuscriptError.closed }
        guard !isRenaming else { throw ManuscriptError.operationInProgress }
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
            name.rangeOfCharacter(from: .controlCharacters) == nil,
            !name.contains("/"), !name.contains(":")
        else { throw ManuscriptError.invalidName }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }
        guard name.utf8.count <= 255 else { throw ManuscriptError.invalidName }
        if name == url.lastPathComponent { return }
        guard !isComposing else { throw ManuscriptError.composing }
        guard !editorHasPendingChanges else { throw ManuscriptError.editorUnavailable }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        isRenaming = true
        autoSaveTask?.cancel()
        externalTask?.cancel()
        defer {
            isRenaming = false
            renameTask = nil
            if !isClosed {
                scheduleExternalCheck()
                scheduleAutoSave()
            }
        }
        guard await save(.explicit) else {
            throw CocoaError(
                .fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: issue ?? "正文尚未保存，请稍后重试。"])
        }
        guard !isClosed else { throw ManuscriptError.closed }
        let task = Task { @MainActor in
            let snapshot = try await self.files.rename(
                self.url, to: destination, expectedRevision: self.savedSnapshot.revision)
            self.url = destination
            self.savedSnapshot = snapshot
            self.fileUnavailable = false
            self.issue = nil
            // A rename never replaces the editor document or clears its history.
            self.restartWatcher()
        }
        renameTask = task
        do { try await task.value } catch {
            if error as? ManuscriptError == .sourceChanged {
                hasConflict = true
                keptConflictingDraft = false
                issue = error.localizedDescription
            }
            throw error
        }
    }

    private func restartWatcher() {
        watcher?.stop()
        watcher = nil
        guard watchesFile, !isClosed else { return }
        watcher = DocumentWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleExternalCheck() }
        }
    }
    private func drainSaves() async -> Bool {
        do {
            if fileUnavailable {
                let latest = try await files.read(url)
                guard latest.revision == savedSnapshot.revision else {
                    throw ManuscriptError.sourceChanged
                }
                fileUnavailable = false
                issue = nil
            }
            while draftSource != nil {
                guard !isComposing, !editorRecoveryRequired, !hasConflict, !isClosed,
                    !editorHasPendingChanges
                else {
                    return false
                }
                let capturedGeneration = generation
                let candidate = serializedSource()
                if candidate == savedSnapshot.source {
                    draftSource = nil
                    savedGeneration = capturedGeneration
                    issue = nil
                    continue
                }
                let snapshot = try await files.write(
                    url, source: candidate, expectedRevision: savedSnapshot.revision)
                savedSnapshot = snapshot
                savedGeneration = capturedGeneration
                if generation == capturedGeneration { draftSource = nil }
                successfulSaveCount += 1
                lastSavedAt = Date()
                issue = nil
            }
            return !editorHasPendingChanges
        } catch {
            issue = error.localizedDescription
            if error as? ManuscriptError == .sourceChanged {
                hasConflict = true
                keptConflictingDraft = false
            }
            if error as? ManuscriptError == .missingFile
                || error as? ManuscriptError == .notWritable
            {
                fileUnavailable = true
            }
            Self.logger.error(
                "Save failed for \(self.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    public func scheduleExternalCheck() {
        guard !isClosed else { return }
        externalTask?.cancel()
        externalTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.externalTask = nil
            await self.checkExternalChanges()
        }
    }
    public func checkExternalChanges() async {
        guard !isClosed, !editorRecoveryRequired else { return }
        if isSaving || isRenaming {
            pendingExternalCheck = true
            return
        }
        let checkedURL = url
        let baseline = savedSnapshot.revision
        do {
            let first = try await files.read(url)
            if first.revision == baseline || (hasConflict && conflictRevision == first.revision) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
            let stable = try await files.read(url)
            guard !isClosed, !isRenaming, checkedURL == url else { return }
            guard stable.revision == first.revision, savedSnapshot.revision == baseline, !isSaving
            else {
                scheduleExternalCheck()
                return
            }
            if !hasUnsavedChanges, !isComposing, let prepareForExternalReload {
                guard await prepareForExternalReload() else { return }
                guard !isClosed, !isRenaming, checkedURL == url else { return }
                guard savedSnapshot.revision == baseline, !isSaving else {
                    scheduleExternalCheck()
                    return
                }
            }
            if hasUnsavedChanges || isComposing {
                hasConflict = true
                if conflictRevision != stable.revision { keptConflictingDraft = false }
                conflictRevision = stable.revision
                issue = ManuscriptError.sourceChanged.localizedDescription
                autoSaveTask?.cancel()
            } else {
                acceptExternal(stable)
            }
        } catch is CancellationError { return } catch {
            guard !isClosed, !isRenaming, checkedURL == url else { return }
            issue = error.localizedDescription
            fileUnavailable = true
        }
    }
    public func keepDraft() {
        keptConflictingDraft = true
        autoSaveTask?.cancel()
    }
    @discardableResult public func loadExternalVersion() async -> Bool {
        guard !isSaving, !isComposing, !isClosed else { return false }
        do {
            acceptExternal(try await files.read(url))
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }
    private func acceptExternal(_ snapshot: FileSnapshot) {
        autoSaveTask?.cancel()
        savedSnapshot = snapshot
        confirmedEditorSource = ManuscriptCodec.editorSource(snapshot.source)
        draftSource = nil
        editorHasPendingChanges = false
        generation += 1
        savedGeneration = generation
        documentRevision += 1
        lastEditorSequence = 0
        editorHasChangedDocument = false
        editorCanUndo = false
        editorCanRedo = false
        hasConflict = false
        conflictRevision = nil
        keptConflictingDraft = false
        issue = nil
        editorNotice = nil
        fileUnavailable = false
        externalReloadCount += 1
    }
    public func writeCopy(to destination: URL) async throws -> FileSnapshot {
        guard !isComposing else { throw ManuscriptError.composing }
        guard !editorHasPendingChanges else { throw ManuscriptError.editorUnavailable }
        return try await files.writeCopy(destination, source: serializedSource())
    }
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        autoSaveTask?.cancel()
        externalTask?.cancel()
        watcher?.stop()
        watcher = nil
        prepareForExternalReload = nil
        draftSource = nil
        outline = []
        editorCanUndo = false
        editorCanRedo = false
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}
