import AppKit
import ManuscriptCore
import UniformTypeIdentifiers

@MainActor
enum DocumentOpenPanel {
    static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文档"
        panel.message = "选择一个或多个 Markdown 文档。"
        panel.allowedContentTypes = ManuscriptCodec.markdownExtensions.sorted().compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.prompt = "打开"
        // AppKit owns the footer's layout, accessibility and action routing. Its
        // native New Document switch is SPI on macOS 26; isolate and check it
        // here instead of moving private views or placing an overlay by coordinates.
        // With no accessory view the system never adds an Options disclosure.
        if panel.responds(to: NSSelectorFromString("_setShowNewDocumentButton:")),
            panel.responds(to: NSSelectorFromString("_setNewDocumentButtonTitle:"))
        {
            panel.setValue("新建文稿", forKey: "newDocumentButtonTitle")
            panel.setValue(true, forKey: "showNewDocumentButton")
        }
        return panel
    }
}

/// The native picker dispatches New Document to the shared document controller.
/// Only that action is bridged; DocumentSession owns contents, saving and recovery.
@MainActor
final class ReaderDocumentController: NSDocumentController {
    override var defaultType: String? { "net.daringfireball.markdown" }
    override func newDocument(_ sender: Any?) {
        ApplicationController.shared.newDocument()
    }
}
