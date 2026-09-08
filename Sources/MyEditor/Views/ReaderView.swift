import ManuscriptCore
import SwiftUI

struct ReaderView: View {
    let session: DocumentSession
    let application: ApplicationController
    var body: some View {
        let railWidth = session.primaryHeadings.isEmpty ? 0 : 58
        let bodyOpticalOffset = session.primaryHeadings.isEmpty ? 0 : 8
        VStack(spacing: 0) {
            if session.hasConflict || session.issue != nil {
                DocumentNotice(session: session, application: application)
            }
            HStack(spacing: 0) {
                if !session.primaryHeadings.isEmpty {
                    ChapterRail(session: session, application: application)
                        .frame(width: 58).padding(.vertical, 28).zIndex(1)
                }
                MarkdownWebEditor(
                    session: session, application: application,
                    configuration: MarkdownEditorConfiguration(
                        session: session, application: application,
                        railOffset: railWidth,
                        bodyOpticalOffset: bodyOpticalOffset)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    application.revealInFinder(session)
                } label: {
                    Label("在访达中打开", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .help(session.url.path)
                .disabled(session.isRenaming || session.isClosed)
                Spacer()
                Picker(
                    "显示样式",
                    selection: Binding(
                        get: { session.showsSource },
                        set: { session.showsSource = $0 }
                    )
                ) {
                    Text("源码").tag(true)
                    Text("渲染").tag(false)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .fixedSize()
                .disabled(!session.editorReady || session.isClosing || session.isComposing)
                .help("切换 Markdown 源码预览与渲染视图")
                .accessibilityLabel("显示样式")
                Divider().frame(height: 12).padding(.horizontal, 4)
                FontSizeMenu(application: application)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if application.isFileDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .tint(application.preferences.accentColor)
        .accentColor(application.preferences.accentColor)
        .onChange(of: session.hasUnsavedChanges) { application.updateWindow(for: session) }
        .onChange(of: session.url) { application.updateWindow(for: session) }
    }
}

private struct DocumentNotice: View {
    let session: DocumentSession
    let application: ApplicationController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                session.hasConflict
                    ? (session.keptConflictingDraft ? "草稿已保留，写回已暂停。" : "源文件已在其他应用中更改。")
                    : (session.issue ?? ""), systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            HStack {
                if session.editorRecoveryRequired {
                    Button("恢复最近同步的正文") { application.editor(for: session)?.recover() }
                } else if session.hasConflict {
                    if !session.keptConflictingDraft { Button("保留草稿") { session.keepDraft() } }
                    Button("载入外部版本") { application.loadExternal(session) }
                } else {
                    Button("重试保存") { Task { await application.save(session, reason: .explicit) } }
                }
                Button("另存副本…") { Task { await application.saveCopy(session) } }
            }.controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.1))
    }
}
