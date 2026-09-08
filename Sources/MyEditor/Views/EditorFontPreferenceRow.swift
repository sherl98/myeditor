import SwiftUI

struct EditorFontPreferenceRow: View {
    let title: String
    let role: EditorFontRole
    @Binding var selection: EditorFontSelection
    let catalog: EditorFontCatalog

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                FontFamilySelector(selection: $selection, role: role, catalog: catalog)
                FontFaceSelector(selection: $selection, role: role, catalog: catalog)
            }
        }
    }
}

private struct FontFamilySelector: View {
    @Binding var selection: EditorFontSelection
    let role: EditorFontRole
    let catalog: EditorFontCatalog
    @State private var showsPicker = false

    private var title: String {
        switch selection {
        case .systemDefault where role == .content,
            .systemMonospaced where role == .code:
            role.systemTitle
        case .installed(let postScriptName):
            catalog.face(for: selection)?.localizedFamilyName ?? "\(postScriptName)（不可用）"
        default:
            role.systemTitle
        }
    }

    var body: some View {
        Button {
            showsPicker.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 188, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            FontFamilyPopover(selection: $selection, role: role, catalog: catalog)
        }
        .help("选择\(role == .content ? "正文" : "代码")字体家族")
        .accessibilityLabel("\(role == .content ? "正文" : "代码")字体家族")
        .accessibilityValue(title)
    }
}

private struct FontFaceSelector: View {
    @Binding var selection: EditorFontSelection
    let role: EditorFontRole
    let catalog: EditorFontCatalog

    private var faces: [InstalledFontFace] {
        catalog.family(for: selection, role: role)?.faces ?? []
    }

    private var title: String {
        switch selection {
        case .installed:
            catalog.face(for: selection)?.localizedFaceName ?? "不可用"
        default:
            "常规"
        }
    }

    var body: some View {
        Picker("", selection: $selection) {
            if faces.isEmpty {
                Text(title).tag(selection)
            } else {
                ForEach(faces) { face in
                    Text(face.localizedFaceName).tag(face.selection)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 116)
        .disabled(faces.count <= 1)
        .help(faces.count <= 1 ? title : "选择字体字形")
        .accessibilityLabel("字体字形")
        .accessibilityValue(title)
    }
}

private struct FontFamilyPopover: View {
    @Binding var selection: EditorFontSelection
    let role: EditorFontRole
    let catalog: EditorFontCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var selectedFamilyID: String? {
        catalog.family(for: selection, role: role)?.id
    }

    private var filteredFamilies: [InstalledFontFamily] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return catalog.families(for: role) }
        return catalog.families(for: role).filter { family in
            family.localizedName.localizedCaseInsensitiveContains(needle)
                || family.familyName.localizedCaseInsensitiveContains(needle)
                || family.faces.contains {
                    $0.localizedFaceName.localizedCaseInsensitiveContains(needle)
                        || $0.postScriptName.localizedCaseInsensitiveContains(needle)
                }
        }
    }

    private var systemSelected: Bool {
        selection == role.defaultSelection
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("搜索字体", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("搜索字体")
            ScrollView {
                LazyVStack(spacing: 2) {
                    familyButton(title: role.systemTitle, subtitle: nil, selected: systemSelected) {
                        selection = role.defaultSelection
                    }
                    Divider().padding(.vertical, 4)
                    if filteredFamilies.isEmpty {
                        Text("没有匹配的字体")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(filteredFamilies) { family in
                            familyButton(
                                title: family.localizedName,
                                subtitle: family.familyName == family.localizedName
                                    ? nil : family.familyName,
                                selected: selectedFamilyID == family.id
                            ) {
                                selection = family.preferredFace.selection
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 330, height: 380)
        .task { searchFocused = true }
    }

    private func familyButton(
        title: String,
        subtitle: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 6 : 4)
            .background(
                selected ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
