import Darwin
import Dispatch
import Foundation

/// Watches only the selected file. Opening its parent directory would require a
/// separate privacy grant even when the user has already granted file access.
/// Its queue owns all descriptors and sources; cancel handlers close each descriptor once.
public final class DocumentWatcher: @unchecked Sendable {
    private let state: State

    public init(url: URL, changed: @escaping @Sendable () -> Void) {
        let state = State(url: url, changed: changed)
        self.state = state
        // O_EVTONLY can wait for a File Provider. Never open it on the caller's
        // thread, including via dispatch_sync from a document window.
        state.queue.async { state.start() }
    }

    public func stop() {
        let state = state
        state.queue.async { state.stop() }
    }

    deinit { stop() }

    /// All mutable state lives on this queue. Teardown captures this storage,
    /// not the watcher being deinitialized, and never waits on a cloud file.
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "local.novelreader.file-watcher", qos: .utility)
        private let url: URL
        private let changed: @Sendable () -> Void
        private var fileSource: DispatchSourceFileSystemObject?
        private var retrySource: DispatchSourceTimer?
        private var stopped = false

        init(url: URL, changed: @escaping @Sendable () -> Void) {
            self.url = url
            self.changed = changed
        }

        func start() {
            guard !stopped else { return }
            attachFile()
            // Catch changes that happened between reading the file and arming
            // the asynchronous watcher.
            changed()
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            fileSource?.cancel()
            retrySource?.cancel()
            fileSource = nil
            retrySource = nil
        }

        private func attachFile() {
            fileSource?.cancel()
            fileSource = makeSource(path: url.path) { [weak self] in
                guard let self, !self.stopped else { return }
                // Atomic saves replace the inode. Reopen the selected path so
                // subsequent edits are observed on the replacement file.
                self.attachFile()
                self.changed()
            }
            if fileSource != nil {
                retrySource?.cancel()
                retrySource = nil
            } else if retrySource == nil {
                // A rename/delete may precede recreation. Retry only this file,
                // without monitoring or enumerating the surrounding directory.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
                timer.setEventHandler { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.attachFile()
                    if self.fileSource != nil { self.changed() }
                }
                retrySource = timer
                timer.resume()
            }
        }

        private func makeSource(path: String, handler: @escaping @Sendable () -> Void)
            -> DispatchSourceFileSystemObject?
        {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: queue)
            source.setEventHandler(handler: handler)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return source
        }
    }
}
