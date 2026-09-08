import AppKit
import ManuscriptCore
import SwiftUI

final class DocumentWindow: NSWindow {
    var openDocument: (() -> Void)?
    override func newWindowForTab(_ sender: Any?) { openDocument?() }
}

@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuDelegate
{
    let session: DocumentSession
    unowned let application: ApplicationController
    var permitClose = false
    private static let searchItem = NSToolbarItem.Identifier("reader.search")
    private static let chapterItem = NSToolbarItem.Identifier("reader.chapters")
    private static let controlsItem = NSToolbarItem.Identifier("reader.controls")
    private let chapterOverflowMenu = NSMenu(title: "目录")
    private let controlsOverflowMenu = NSMenu(title: "阅读设置与编辑")
    private let titlePresentation = DocumentTitlePresentation()

    init(session: DocumentSession, application: ApplicationController) {
        self.session = session
        self.application = application
        let size = application.preferences.windowSize
        let window = DocumentWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = session.url.lastPathComponent
        window.titleVisibility = .hidden
        window.representedURL = session.url
        window.tabbingIdentifier = "NovelReader.documents"
        window.tabbingMode = .preferred
        window.acceptsMouseMovedEvents = true
        window.tab.title = session.url.lastPathComponent
        window.tab.attributedTitle = Self.tabTitle(session.url.lastPathComponent)
        window.tab.toolTip = session.url.path
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.minSize = ReaderPreferences.minimumWindowSize
        window.center()
        super.init(window: window)
        chapterOverflowMenu.identifier = NSUserInterfaceItemIdentifier("reader.chapters.menu")
        controlsOverflowMenu.identifier = NSUserInterfaceItemIdentifier("reader.controls.menu")
        window.delegate = self
        window.openDocument = { [weak application] in application?.openPicker() }
        let tabActions = NSHostingView(
            rootView: DocumentTitleView(
                session: session, application: application, presentation: titlePresentation
            ) { [weak self] in
                self?.activateTabActions()
            })
        tabActions.setContentHuggingPriority(.required, for: .horizontal)
        tabActions.setContentCompressionResistancePriority(.required, for: .horizontal)
        window.tab.accessoryView = tabActions
        tabActions.widthAnchor.constraint(equalToConstant: 22).isActive = true
        tabActions.heightAnchor.constraint(equalToConstant: 24).isActive = true
        window.contentView = FileDropHostingView(
            rootView: ReaderView(session: session, application: application),
            application: application)
        let toolbar = NSToolbar(identifier: "NovelReader.readerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.minSize = ReaderPreferences.minimumWindowSize
        chapterOverflowMenu.delegate = self
        controlsOverflowMenu.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private static func tabTitle(_ title: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [.paragraphStyle: paragraph])
    }
    private func activateTabActions() {
        guard let window else { return }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        titlePresentation.isShowingActions.toggle()
    }
    func updateDocumentMetadata() {
        window?.title = session.url.lastPathComponent
        window?.representedURL = session.url
        window?.tab.title = session.url.lastPathComponent
        window?.tab.attributedTitle = Self.tabTitle(session.url.lastPathComponent)
        window?.tab.toolTip = session.url.path
        window?.isDocumentEdited = session.hasUnsavedChanges
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitClose { return true }
        application.requestClose(session)
        return false
    }
    func windowDidBecomeKey(_ notification: Notification) { application.activate(session) }
    func windowDidResignKey(_ notification: Notification) {
        Task { await application.save(session, reason: .focusLoss) }
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, ReaderPreferences.minimumWindowSize.width),
            height: max(frameSize.height, ReaderPreferences.minimumWindowSize.height))
    }
    func windowDidEndLiveResize(_ notification: Notification) { rememberSize() }
    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false { rememberSize() }
    }
    private func rememberSize() {
        if let size = window?.frame.size, window?.styleMask.contains(.fullScreen) == false {
            application.preferences.rememberWindowSize(size)
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.searchItem, .space, Self.chapterItem, .space, Self.controlsItem]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.searchItem {
            item.label = "搜索全文"
            let host = NSHostingView(
                rootView: DocumentSearchView(
                    session: session, application: application,
                    state: application.searchState(for: session)))
            host.setContentHuggingPriority(.init(1), for: .horizontal)
            host.setContentCompressionResistancePriority(.required, for: .horizontal)
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            item.view = host
            // Keep the search field and its actions inside one native toolbar container.
            item.isBordered = true
            item.visibilityPriority = .user
        } else if identifier == Self.chapterItem {
            item.label = "目录"
            item.view = NSHostingView(
                rootView: ChapterMenu(session: session, application: application).frame(
                    width: 48, height: 32))
            let representation = NSMenuItem(title: "目录", action: nil, keyEquivalent: "")
            menuNeedsUpdate(chapterOverflowMenu)
            representation.submenu = chapterOverflowMenu
            item.menuFormRepresentation = representation
        } else if identifier == Self.controlsItem {
            item.label = "阅读设置与编辑"
            let host = NSHostingView(
                rootView: ReaderControls(session: session, application: application).frame(
                    height: 32))
            host.setContentHuggingPriority(.required, for: .horizontal)
            host.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.view = host
            let representation = NSMenuItem(title: "阅读设置与编辑", action: nil, keyEquivalent: "")
            menuNeedsUpdate(controlsOverflowMenu)
            representation.submenu = controlsOverflowMenu
            item.menuFormRepresentation = representation
        } else {
            return nil
        }
        return item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        // NSToolbar copies its menu representation for the overflow pop-up.
        let chapters =
            menu.identifier == chapterOverflowMenu.identifier
            || menu.title == chapterOverflowMenu.title
        let controls =
            menu.identifier == controlsOverflowMenu.identifier
            || menu.title == controlsOverflowMenu.title
        guard chapters || controls else { return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        if chapters {
            if session.outline.isEmpty {
                let empty = NSMenuItem(title: "文档没有标题", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for heading in session.outline {
                let item = NSMenuItem(
                    title: heading.title, action: #selector(navigateFromMenu(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = heading.id
                item.indentationLevel = max(0, heading.level - 1)
                item.state = heading.id == session.activeHeadingID ? .on : .off
                item.isEnabled = session.editorReady && !session.isClosing
                menu.addItem(item)
            }
        } else if controls {
            for theme in ReaderAppearance.allCases {
                let item = NSMenuItem(
                    title: theme.title, action: #selector(changeTheme(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = theme.rawValue
                item.state = theme == application.preferences.appearance ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let edit = NSMenuItem(
                title: session.isEditing ? "完成" : "编辑",
                action: #selector(toggleEditingFromMenu(_:)), keyEquivalent: "")
            edit.target = self
            edit.isEnabled = session.editorReady && !session.isClosing
            menu.addItem(edit)
        }
    }
    @objc private func navigateFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { application.navigate(session, to: id) }
    }
    @objc private func changeTheme(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String,
            let theme = ReaderAppearance(rawValue: value)
        {
            application.setAppearance(theme)
        }
    }
    @objc private func toggleEditingFromMenu(_ sender: NSMenuItem) {
        application.toggleEditing(session)
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    unowned let application: ApplicationController
    init(controller: ApplicationController) {
        application = controller
        let desiredFrameSize = controller.preferences.windowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: desiredFrameSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MyEditor"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = ReaderPreferences.minimumWindowSize
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = FileDropHostingView(
            rootView: WelcomeView(application: controller), application: controller)
        super.init(window: window)
        window.delegate = self
        window.setFrame(NSRect(origin: window.frame.origin, size: desiredFrameSize), display: false)
        window.minSize = ReaderPreferences.minimumWindowSize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowDidBecomeKey(_ notification: Notification) { application.activeDocumentID = nil }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, ReaderPreferences.minimumWindowSize.width),
            height: max(frameSize.height, ReaderPreferences.minimumWindowSize.height))
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if let size = window?.frame.size { application.preferences.rememberWindowSize(size) }
    }
    func windowDidResize(_ notification: Notification) {
        if window?.inLiveResize == false, let size = window?.frame.size {
            application.preferences.rememberWindowSize(size)
        }
    }
}
