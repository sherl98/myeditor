#if DEBUG
    import Foundation
    import AppKit

    /// Integration of a real, isolated file pasteboard with the production drop
    /// receiver and native tab group. This does not synthesize pointer events.
    @MainActor enum DropIntegrationChecks {
        private struct Failure: Error { let message: String }

        static func run(application: ApplicationController) async {
            guard
                let path = Bundle.main.object(forInfoDictionaryKey: "NRDiagnosticsDirectory")
                    as? String
            else { return }
            let directory = URL(fileURLWithPath: path)
            let urls = ["拖放样例 1.md", "drop-check-2.md", "drop-check-3.md"].map {
                directory.appendingPathComponent($0)
            }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            var completed: [String] = []
            var failure: String?
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw Failure(message: name) }
                completed.append(name)
            }
            do {
                for (index, url) in urls.enumerated() {
                    try "# 拖放验证 \(index + 1)\n\n## 示例章节\n\n本地文档批量拖放验证。\n".write(
                        to: url, atomically: true, encoding: .utf8)
                }
                try check(
                    pasteboard.writeObjects(urls.map { $0 as NSURL }),
                    "Real pasteboard accepts three file URLs")
                try check(
                    NativeFileDrop.urls(from: pasteboard) == urls,
                    "File URL decoding preserves order, spaces and Chinese paths")
                try check(
                    NativeFileDrop.perform(pasteboard, application: application),
                    "Production drop receiver accepts files")
                await application.waitForValidationOpen()
                let sessions = application.store.sessions
                try check(
                    sessions.map(\.url) == urls, "Batch opens three documents in pasteboard order")
                try check(
                    application.activeSession?.url == urls.last, "Last dropped document is active")
                let windows = sessions.compactMap { application.validationWindow(for: $0) }
                let group = windows.first?.tabGroup
                try check(
                    windows.count == 3 && group?.windows.count == 3
                        && windows.allSatisfy { $0.tabGroup === group },
                    "Every document belongs to one native window tab group")
                let identities = sessions.map(\.id)
                _ = NativeFileDrop.perform(pasteboard, application: application)
                await application.waitForValidationOpen()
                try check(
                    application.store.sessions.map(\.id) == identities,
                    "Repeated drop focuses existing documents without duplicate sessions")
                pasteboard.clearContents()
                pasteboard.setString("ordinary text", forType: .string)
                try check(
                    !NativeFileDrop.perform(pasteboard, application: application),
                    "Plain text is not treated as a file drop")
            } catch let error as Failure { failure = error.message } catch {
                failure = error.localizedDescription
            }
            let result: [String: Any] = [
                "passed": failure == nil, "checks": completed, "failure": failure ?? "",
                "scope":
                    "Real NSPasteboard, production file URL receiver, document store and native NSWindow tab group; physical pointer delivery is not asserted",
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            {
                try? data.write(to: directory.appendingPathComponent("drop-checks.json"))
            }
        }
    }
#endif
