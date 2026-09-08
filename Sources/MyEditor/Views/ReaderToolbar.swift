import ManuscriptCore
import SwiftUI

struct ChapterMenu: View {
    let session: DocumentSession
    let application: ApplicationController
    var body: some View {
        Menu {
            if session.outline.isEmpty { Text("文档没有标题") }
            ForEach(session.outline) { heading in
                Button {
                    application.navigate(session, to: heading.id)
                } label: {
                    let title =
                        String(repeating: "　", count: max(0, heading.level - 1)) + heading.title
                    if heading.id == session.activeHeadingID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(width: 48, height: 32)
        .help("目录 · \(session.outline.count) 个标题")
        .accessibilityLabel("目录")
    }
}

struct ReaderControls: View {
    let session: DocumentSession
    let application: ApplicationController
    var body: some View {
        @Bindable var preferences = application.preferences
        HStack(spacing: 8) {
            Menu {
                ForEach(ReaderAppearance.allCases) { theme in
                    Button {
                        application.setAppearance(theme)
                    } label: {
                        if preferences.appearance == theme {
                            Label(theme.title, systemImage: "checkmark")
                        } else {
                            Text(theme.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton).fixedSize().help("外观").accessibilityLabel("外观")
            Divider().frame(height: 16)
            Button {
                application.toggleEditing(session)
            } label: {
                Label(
                    session.isEditing ? "完成" : "编辑",
                    systemImage: session.isEditing ? "checkmark.square" : "square.and.pencil"
                )
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))
            }
            .tint(session.isEditing ? preferences.accentColor : .primary)
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .disabled(session.isClosing || !session.editorReady)
            .help(session.isEditing ? "完成编辑并保存" : "原位编辑全文")
            .animation(.easeInOut(duration: 0.18), value: session.isEditing)
        }
        .font(.system(size: 13))
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct FontSizeMenu: View {
    let application: ApplicationController
    var body: some View {
        Menu {
            ForEach(Array(stride(from: 80, through: 140, by: 10)), id: \.self) { percent in
                Button {
                    application.preferences.fontPercent = percent
                } label: {
                    if application.preferences.fontPercent == percent {
                        Label("\(percent)%", systemImage: "checkmark")
                    } else {
                        Text("\(percent)%")
                    }
                }
            }
        } label: {
            Text("\(application.preferences.fontPercent)%").monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .controlSize(.mini)
        .fixedSize()
        .help("调整正文字号")
        .accessibilityLabel("正文字号")
    }
}

struct PreferencesView: View {
    let application: ApplicationController
    var body: some View {
        @Bindable var preferences = application.preferences
        Form {
            Picker(
                "外观",
                selection: Binding(
                    get: { preferences.appearance },
                    set: { application.setAppearance($0) }
                )
            ) {
                ForEach(ReaderAppearance.allCases) { theme in Text(theme.title).tag(theme) }
            }
            Picker("正文字号", selection: $preferences.fontPercent) {
                ForEach(Array(stride(from: 80, through: 140, by: 10)), id: \.self) { percent in
                    Text("\(percent)%").tag(percent)
                }
            }
            EditorFontPreferenceRow(
                title: "正文字体",
                role: .content,
                selection: $preferences.contentFont,
                catalog: preferences.fontCatalog
            )
            EditorFontPreferenceRow(
                title: "代码字体",
                role: .code,
                selection: $preferences.codeFont,
                catalog: preferences.fontCatalog
            )
            Picker("强调色", selection: $preferences.accentChoice) {
                ForEach(ReaderAccent.allCases) { accent in
                    Label {
                        Text(accent.title)
                    } icon: {
                        Image(nsImage: accent.swatchImage)
                            .renderingMode(.original)
                    }
                    .tag(accent)
                }
            }
            .pickerStyle(.menu)
            Text("停止输入 800 毫秒后自动同步到源文件。撤销历史保留到文档关闭。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).frame(width: 500, height: 390)
        .tint(preferences.accentColor)
    }
}
