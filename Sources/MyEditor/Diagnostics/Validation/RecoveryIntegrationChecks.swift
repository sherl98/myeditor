#if DEBUG
    import Foundation
    import ManuscriptCore

    @MainActor enum RecoveryIntegrationChecks {
        struct Failure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }
        static func run(application: ApplicationController, directory: URL) async throws -> [String]
        {
            let url = directory.appendingPathComponent("recovery-original.md")
            try "# Saved\n".write(to: url, atomically: true, encoding: .utf8)
            application.open([url])
            await application.waitForValidationOpen()
            guard let session = application.activeSession else {
                throw Failure(message: "Recovery fixture opens")
            }
            func wait(_ predicate: () -> Bool) async throws {
                for _ in 0..<250 {
                    if predicate() { return }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw Failure(message: "Recovery transition timed out")
            }
            try await wait { session.editorReady }
            guard let bridge = application.editor(for: session) as? MarkdownWebEditor.Coordinator,
                let webView = bridge.webView
            else { throw Failure(message: "Recovery bridge exists") }
            session.beginEditing()
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEdit('Confirmed draft')")
            try await wait { session.source.contains("Confirmed draft") }
            let expected = session.source
            let diskBefore = try String(contentsOf: url, encoding: .utf8)
            let oldRevision = session.documentRevision
            // Exercise the actual termination delegate and subsequent real page load;
            // no user's shared WebKit process is killed by this test.
            bridge.webViewWebContentProcessDidTerminate(webView)
            guard session.editorRecoveryRequired,
                !(await application.save(session, reason: .explicit))
            else { throw Failure(message: "Interrupted editor blocks original write") }
            _ = try await session.writeRecoveryCopy(
                to: directory.appendingPathComponent("recovery-copy.md"))
            guard try String(contentsOf: url, encoding: .utf8) == diskBefore else {
                throw Failure(message: "Export changed original")
            }
            bridge.recover()
            try await wait { session.editorReady }
            let restored =
                try await bridge.evaluateForValidation("return window.MyEditor.inspect().source")
                as? String
            guard restored == expected, session.documentRevision > oldRevision else {
                throw Failure(message: "Reload restores confirmed snapshot")
            }
            _ = try await bridge.evaluateForValidation(
                "return await window.MyEditor.validationEdit('After recovery')")
            guard await application.save(session, reason: .explicit),
                try String(contentsOf: url, encoding: .utf8).contains("After recovery")
            else { throw Failure(message: "Recovered editor saves new input") }
            application.requestClose(session)
            try await wait { session.isClosed }
            return [
                "Termination callback pauses original writes",
                "Confirmed recovery copy preserves original",
                "Real WebKit reload restores the confirmed snapshot",
                "Recovered editor accepts and saves a new sequence",
            ]
        }
    }
#endif
