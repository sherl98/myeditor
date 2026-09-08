import Foundation
import ManuscriptCore

extension Checks {
    func editorRecovery() async throws {
        let s = try await session("recovery", source: "# Saved\n")
        defer { s.close() }
        s.updateHistory(canUndo: true, canRedo: true)
        try expect(
            !s.canUndo && !s.canRedo,
            "Selection-only history cannot enable undo on an untouched document")
        edit(s, suffix: "\nConfirmed draft")
        try expect(s.canUndo, "Real content change enables available editor history")
        s.notePendingEditorChanges()
        s.confirmEditorSequence(0, revision: s.documentRevision)
        try expect(s.editorHasPendingChanges, "Old sequence cannot settle pending input")
        s.confirmEditorSequence(1, revision: s.documentRevision)
        try expect(
            !s.editorHasPendingChanges, "No-op input settles without duplicate source transfer")
        s.setComposing(true)
        edit(s, suffix: "candidate")
        let revision = s.documentRevision
        s.notePendingEditorChanges()
        s.editorDidTerminate()
        try expect(
            s.editorRecoveryRequired && !s.editorReady && !s.isComposing,
            "Termination separates unavailable editor from composition")
        try expect(!(await s.save(.explicit)), "Interrupted editor never overwrites original")
        let copy = directory.appendingPathComponent("recovered.md")
        _ = try await s.writeRecoveryCopy(to: copy)
        try expect(
            try String(contentsOf: copy, encoding: .utf8) == "# Saved\n\nConfirmed draft\n",
            "Recovery copy excludes unconfirmed IME candidate")
        try expect(
            try String(contentsOf: s.url, encoding: .utf8) == "# Saved\n",
            "Recovery export preserves original")
        s.receiveEditorSource("stale", sequence: 999, revision: revision)
        s.prepareEditorRecovery()
        try expect(
            s.source == "# Saved\n\nConfirmed draft" && s.documentRevision > revision,
            "Explicit recovery restores confirmed draft with a fresh revision")
        s.setEditorReady(true)
        s.receiveEditorSource(s.source + "\nNew edit", sequence: 1, revision: s.documentRevision)
        try expect(
            await s.save(.explicit), "Recovered editor accepts fresh sequence and saves normally")
        try expect(
            try String(contentsOf: s.url, encoding: .utf8).hasSuffix("New edit\n"),
            "Recovered new edits reach disk")
    }
}
