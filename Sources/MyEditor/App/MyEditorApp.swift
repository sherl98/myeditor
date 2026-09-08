import AppKit
import ManuscriptCore
import SwiftUI

@main
struct MyEditorApp: App {
    @NSApplicationDelegateAdaptor(ReaderAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { PreferencesView(application: ApplicationController.shared) }
            .commands { ReaderCommands(application: ApplicationController.shared) }
    }
}

@MainActor
final class ReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ApplicationController.shared.launch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        ApplicationController.shared.reopen()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationController.shared.terminate()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        ApplicationController.shared.open(urls)
    }
}
