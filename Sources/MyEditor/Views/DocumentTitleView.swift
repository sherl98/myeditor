import ManuscriptCore
import Observation
import SwiftUI

@Observable @MainActor
final class DocumentTitlePresentation {
    var isShowingActions = false
}

struct DocumentTitleView: View {
    let session: DocumentSession
    let application: ApplicationController
    @Bindable var presentation: DocumentTitlePresentation
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isClosing || session.isRenaming)
        .help("重命名或另存为 · \(session.url.lastPathComponent)")
        .accessibilityLabel("文件操作：\(session.url.lastPathComponent)")
        .popover(isPresented: $presentation.isShowingActions, arrowEdge: .bottom) {
            DocumentFileActionsView(session: session, application: application) {
                presentation.isShowingActions = false
            }
        }
    }
}

private struct DocumentFileActionsView: View {
    let session: DocumentSession
    let application: ApplicationController
    let dismiss: () -> Void
    @State private var name: String
    @State private var error: String?
    @State private var isSubmitting = false
    @FocusState private var nameIsFocused: Bool

    init(
        session: DocumentSession, application: ApplicationController, dismiss: @escaping () -> Void
    ) {
        self.session = session
        self.application = application
        self.dismiss = dismiss
        _name = State(initialValue: session.url.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("名称：").foregroundStyle(.secondary)
                TextField("文档名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameIsFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("文档名称")
                Text(".md").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("位置：").foregroundStyle(.secondary)
                Label(
                    session.url.deletingLastPathComponent().lastPathComponent, systemImage: "folder"
                )
                .lineLimit(1).truncationMode(.middle)
                .help(session.url.deletingLastPathComponent().path)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(
                    horizontal: false, vertical: true)
            }
            HStack {
                if isSubmitting { ProgressView().controlSize(.small) }
                Button("另存为…", action: saveCopy)
                    .disabled(isSubmitting)
                Spacer()
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("重命名", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18).frame(width: 380)
        .disabled(isSubmitting)
        .onAppear { nameIsFocused = true }
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task { @MainActor in
            if let message = await application.rename(session, to: name) {
                error = message
                isSubmitting = false
                nameIsFocused = true
            } else {
                dismiss()
            }
        }
    }

    private func saveCopy() {
        guard !isSubmitting else { return }
        dismiss()
        Task { @MainActor in
            await Task.yield()
            _ = await application.saveCopy(session)
        }
    }
}
