#if DEBUG
    import SwiftUI
    import AppKit

    /// A debug-only, real NSDraggingSession source avoids moving unrelated Finder
    /// files during automated acceptance. It emits the same file-URL pasteboard type.
    struct ValidationDropSource: NSViewRepresentable {
        func makeNSView(context: Context) -> FileDragButton {
            let button = FileDragButton(title: "拖放验证 · 3 份文档", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.image = NSImage(
                systemSymbolName: "document.on.document", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            if let directory = Bundle.main.object(forInfoDictionaryKey: "NRDiagnosticsDirectory")
                as? String
            {
                for index in 1...3 {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(
                        "drop-check-\(index).md")
                    do {
                        try "# 拖放验证 \(index)\n\n## 示例章节\n\n这是一份独立的 Markdown 拖放样例。\n".write(
                            to: url, atomically: true, encoding: .utf8)
                        button.urls.append(url)
                    } catch { button.isEnabled = false }
                }
            }
            return button
        }
        func updateNSView(_ view: FileDragButton, context: Context) {}
    }

    final class FileDragButton: NSButton, NSDraggingSource {
        var urls: [URL] = []
        override func mouseDown(with event: NSEvent) {
            guard !urls.isEmpty else { return }
            RuntimeDiagnostics.record("drag_source_started", documents: 0, documentBytes: 0)
            let point = convert(event.locationInWindow, from: nil)
            let items = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(
                    NSRect(x: point.x + CGFloat(index * 5), y: point.y, width: 32, height: 38),
                    contents: NSImage(
                        systemSymbolName: "text.document", accessibilityDescription: nil))
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }
        func draggingSession(
            _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation { .copy }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            RuntimeDiagnostics.record("drag_source_began", documents: 0, documentBytes: 0)
        }
        func draggingSession(
            _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
        ) {
            let localPoint = window?.convertPoint(fromScreen: screenPoint) ?? .zero
            RuntimeDiagnostics.record(
                "drag_source_ended_\(operation.rawValue)_x\(Int(localPoint.x))_y\(Int(localPoint.y))",
                documents: 0, documentBytes: 0)
        }
    }
#endif
