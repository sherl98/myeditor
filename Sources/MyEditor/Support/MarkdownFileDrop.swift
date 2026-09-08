import AppKit
import SwiftUI

@MainActor enum NativeFileDrop {
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        return pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func perform(_ pasteboard: NSPasteboard, application: ApplicationController) -> Bool {
        application.isFileDropTargeted = false
        return application.acceptDrop(urls(from: pasteboard))
    }
}

/// Keep Finder pasteboard conversion at the native hosting boundary. Reading
/// file URLs synchronously also preserves the ordering of a multi-file drag.
final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    weak var application: ApplicationController?
    private var minimumContentHeight: NSLayoutConstraint?

    init(rootView: Content, application: ApplicationController) {
        self.application = application
        super.init(rootView: rootView)
        // Auto Layout ignores NSWindow.minSize. Keep a content constraint as
        // well as the controller's interactive resize limit, independent of
        // SwiftUI's intrinsic-size calculations for the document surface.
        sizingOptions = []
        widthAnchor.constraint(
            greaterThanOrEqualToConstant: ReaderPreferences.minimumWindowSize.width
        ).isActive = true
        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 552)
        minimumHeight.isActive = true
        minimumContentHeight = minimumHeight
        registerForDraggedTypes([.fileURL])
    }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        guard let window, bounds.height > 0 else { return }
        let chrome = max(0, window.frame.height - bounds.height)
        let height = max(0, ReaderPreferences.minimumWindowSize.height - chrome)
        if minimumContentHeight?.constant != height { minimumContentHeight?.constant = height }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty
        application?.isFileDropTargeted = accepted
        return accepted ? .copy : []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        application?.isFileDropTargeted = false
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !NativeFileDrop.urls(from: sender.draggingPasteboard).isEmpty
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let application else { return false }
        return NativeFileDrop.perform(sender.draggingPasteboard, application: application)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        application?.isFileDropTargeted = false
    }
}
