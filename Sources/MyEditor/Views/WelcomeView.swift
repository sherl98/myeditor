import SwiftUI

struct WelcomeView: View {
    let application: ApplicationController
    @FocusState private var openFocused: Bool
    @State private var dropAnimation = 0
    private var targeted: Bool { application.isFileDropTargeted }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("随心编阅")
                    .font(.system(size: 30, weight: .semibold))
                Button(action: application.openPicker) {
                    Image(systemName: "document.badge.plus")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            targeted ? application.preferences.accentColor : Color.secondary
                        )
                        .symbolEffect(.bounce, value: dropAnimation)
                        .frame(maxWidth: .infinity).frame(height: 240)
                        .background(
                            .quaternary.opacity(targeted || openFocused ? 0.8 : 0.3),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .focusable()
                .focusEffectDisabled()
                .focused($openFocused)
                .onKeyPress(.space) {
                    application.openPicker()
                    return .handled
                }
                .onKeyPress(.return) {
                    application.openPicker()
                    return .handled
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16).strokeBorder(
                        Color.secondary.opacity(targeted ? 0.5 : 0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                )
                .accessibilityLabel("打开 Markdown 文档")
                .accessibilityHint("点击打开，或拖入一份或多份 Markdown 文档。")
                .onChange(of: targeted) { _, isTargeted in
                    if isTargeted { dropAnimation += 1 }
                }
                if !application.recentDocuments.entries.isEmpty {
                    @Bindable var recents = application.recentDocuments
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { recents.expanded.toggle() }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(recents.expanded ? 90 : 0))
                                Text("最近打开")
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("最近打开")
                        .accessibilityValue(recents.expanded ? "已展开" : "已收起")
                        if recents.expanded {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(recents.entries) { entry in
                                    Button {
                                        application.openRecent(entry)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "text.document").foregroundStyle(
                                                .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.url.lastPathComponent).lineLimit(1)
                                                    .truncationMode(.tail)
                                                Text(entry.url.deletingLastPathComponent().path)
                                                    .font(.caption2).foregroundStyle(.secondary)
                                                    .lineLimit(1).truncationMode(.head)
                                            }
                                            Spacer(minLength: 0)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(
                                            .vertical, 5
                                        ).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).help(entry.path)
                                    .contextMenu { Button("从最近打开中移除") { recents.remove(entry) } }
                                }
                            }
                            .padding(.top, 6)
                            .transition(.opacity)
                        }
                    }
                    .font(.system(size: 13))
                }
            }
            .frame(width: 380).padding(.vertical, 34)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 560)
        }
        .defaultScrollAnchor(.center)
        .safeAreaPadding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        #if DEBUG
            .overlay(alignment: .topLeading) {
                if Bundle.main.object(forInfoDictionaryKey: "NRRunDropChecks") as? Bool == true {
                    ValidationDropSource().frame(width: 185, height: 44).padding(16)
                }
            }
        #endif
        .tint(application.preferences.accentColor)
    }
}
