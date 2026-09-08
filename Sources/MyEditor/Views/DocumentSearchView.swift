import AppKit
import ManuscriptCore
import SwiftUI

struct DocumentSearchView: View {
    let session: DocumentSession
    let application: ApplicationController
    @Bindable var state: DocumentSearchState

    var body: some View {
        HStack(spacing: 4) {
            NativeDocumentSearchField(
                state: state,
                changed: { application.search(session) },
                navigate: { application.findNext(session, by: $0) },
                ended: { application.endSearch(session, returnToDocument: true) }
            )
            .frame(minWidth: 64, maxWidth: .infinity, minHeight: 28)
            Text(state.counter).monospacedDigit().font(.system(size: 11)).foregroundStyle(
                .secondary
            )
            .frame(width: 49).lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel("搜索结果：\(state.current) / \(state.count)")
            Button {
                application.findNext(session, by: -1)
            } label: {
                Image(systemName: "chevron.up").frame(width: 24, height: 28)
            }
            .help("上一处 · ⇧⌘G").accessibilityLabel("上一处匹配")
            .disabled(state.count == 0 || state.isSearching)
            Button {
                application.findNext(session, by: 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: 24, height: 28)
            }
            .help("下一处 · ⌘G").accessibilityLabel("下一处匹配")
            .disabled(state.count == 0 || state.isSearching)
            Menu {
                Button {
                    state.mode = .find
                    state.showsReplacement = false
                    state.focusRequest += 1
                } label: {
                    if state.mode == .find {
                        Label("查找", systemImage: "checkmark")
                    } else {
                        Text("查找")
                    }
                }
                Button {
                    state.mode = .replace
                    state.showsReplacement = true
                } label: {
                    if state.mode == .replace {
                        Label("替换", systemImage: "checkmark")
                    } else {
                        Text("替换")
                    }
                }
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("查找与替换").accessibilityLabel("查找与替换")
            .popover(isPresented: $state.showsReplacement, arrowEdge: .bottom) {
                replacementPanel
            }
        }
        .font(.system(size: 12)).buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 32)
        .tint(.primary)
        .disabled(!session.editorReady || session.isClosing)
    }

    private var replacementPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("替换").font(.headline)
                Spacer()
                Button {
                    state.showsReplacement = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).help("收起替换").accessibilityLabel("收起替换")
            }
            TextField("替换为…", text: $state.replacement)
                .textFieldStyle(.roundedBorder).accessibilityLabel("替换文字")
            HStack {
                Text(state.message ?? (state.query.isEmpty ? "在顶部输入查找关键词" : "\(state.count) 处匹配"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("替换") { application.replace(session, all: false) }
                Button("替换全部") { application.replace(session, all: true) }
            }
            .disabled(
                !state.canReplace || session.isComposing || session.isClosing || session.showsSource
            )
        }
        .padding(16).frame(width: 380)
        .tint(application.preferences.accentColor)
    }
}

// Keep text editing, cancel button hit testing and focus rendering owned by AppKit.
private struct NativeDocumentSearchField: NSViewRepresentable {
    let state: DocumentSearchState
    let changed: () -> Void
    let navigate: (Int) -> Void
    let ended: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索全文"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        field.setAccessibilityLabel("搜索全文")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != state.query,
            (field.currentEditor() as? NSTextView)?.hasMarkedText() != true
        {
            field.stringValue = state.query
        }
        if context.coordinator.lastFocus != state.focusRequest {
            context.coordinator.lastFocus = state.focusRequest
            if state.focusRequest > 0 {
                DispatchQueue.main.async { [weak field] in
                    guard let field else { return }
                    field.window?.makeFirstResponder(field)
                    field.selectText(nil)
                }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeDocumentSearchField
        var lastFocus = 0
        init(_ parent: NativeDocumentSearchField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.state.isFocused = true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.state.isFocused = false
        }
        // Delegate and target/action may both deliver the same edit. Only the
        // first delivery changes the query and creates a request identifier.
        private func synchronize(_ field: NSSearchField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                parent.state.query != field.stringValue
            else { return }
            parent.state.query = field.stringValue
            parent.changed()
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { synchronize(field) }
        }
        @objc func submitted(_ field: NSSearchField) { synchronize(field) }
        func searchFieldDidEndSearching(_ sender: NSSearchField) { synchronize(sender) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
            -> Bool
        {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                (control as? NSSearchField)?.stringValue = ""
                parent.ended()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.navigate(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            }
            return false
        }
    }
}
