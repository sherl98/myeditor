import AppKit
import CoreText
import Observation

enum EditorFontSelection: Codable, Equatable, Hashable {
    case systemDefault
    case systemMonospaced
    case installed(postScriptName: String)
}

enum EditorFontRole: Equatable {
    case content
    case code

    var defaultSelection: EditorFontSelection {
        switch self {
        case .content: .systemDefault
        case .code: .systemMonospaced
        }
    }

    var systemTitle: String {
        switch self {
        case .content: "系统默认"
        case .code: "系统等宽"
        }
    }

    var fallbackWebFace: EditorWebFontFace {
        switch self {
        case .content:
            EditorWebFontFace(family: "system-ui", weight: 400, style: "normal", isGeneric: true)
        case .code:
            EditorWebFontFace(family: "ui-monospace", weight: 400, style: "normal", isGeneric: true)
        }
    }
}

struct EditorWebFontFace: Equatable {
    let family: String
    let weight: Int
    let style: String
    let isGeneric: Bool

    var webOptions: [String: Any] {
        ["family": family, "weight": weight, "style": style, "isGeneric": isGeneric]
    }
}

struct InstalledFontFace: Identifiable, Equatable, Hashable {
    let postScriptName: String
    let familyName: String
    let localizedFamilyName: String
    let localizedFaceName: String
    let cssWeight: Int
    let italic: Bool
    let monospaced: Bool

    var id: String { postScriptName }
    var selection: EditorFontSelection { .installed(postScriptName: postScriptName) }
    var webFace: EditorWebFontFace {
        EditorWebFontFace(
            family: familyName,
            weight: cssWeight,
            style: italic ? "italic" : "normal",
            isGeneric: false
        )
    }
}

struct InstalledFontFamily: Identifiable, Equatable, Hashable {
    let familyName: String
    let localizedName: String
    let faces: [InstalledFontFace]

    var id: String { familyName }
    var preferredFace: InstalledFontFace {
        faces.min { lhs, rhs in
            let lhsScore = abs(lhs.cssWeight - 400) + (lhs.italic ? 1_000 : 0)
            let rhsScore = abs(rhs.cssWeight - 400) + (rhs.italic ? 1_000 : 0)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.localizedFaceName.localizedStandardCompare(rhs.localizedFaceName)
                == .orderedAscending
        } ?? faces[0]
    }
}

@Observable @MainActor
final class EditorFontCatalog {
    private(set) var families: [InstalledFontFamily] = []
    private(set) var monospacedFamilies: [InstalledFontFamily] = []
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var facesByPostScriptName: [String: InstalledFontFace] = [:]
    @ObservationIgnored private var fontObserver: NSObjectProtocol?

    init() {
        reload()
        fontObserver = NotificationCenter.default.addObserver(
            forName: NSFont.fontSetChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func families(for role: EditorFontRole) -> [InstalledFontFamily] {
        switch role {
        case .content: families
        case .code: monospacedFamilies
        }
    }

    func face(for selection: EditorFontSelection) -> InstalledFontFace? {
        guard case .installed(let postScriptName) = selection else { return nil }
        return facesByPostScriptName[postScriptName]
    }

    func family(for selection: EditorFontSelection, role: EditorFontRole) -> InstalledFontFamily? {
        guard let face = face(for: selection) else { return nil }
        return families(for: role).first { family in
            family.faces.contains { $0.postScriptName == face.postScriptName }
        }
    }

    func webFace(for selection: EditorFontSelection, role: EditorFontRole) -> EditorWebFontFace {
        switch selection {
        case .systemDefault where role == .content:
            return role.fallbackWebFace
        case .systemMonospaced where role == .code:
            return role.fallbackWebFace
        case .installed:
            guard let face = face(for: selection), role == .content || face.monospaced else {
                return role.fallbackWebFace
            }
            return face.webFace
        default:
            return role.fallbackWebFace
        }
    }

    func reload() {
        let loaded = Self.loadFamilies()
        families = loaded
        monospacedFamilies = loaded.compactMap { family in
            let faces = family.faces.filter(\.monospaced)
            guard !faces.isEmpty else { return nil }
            return InstalledFontFamily(
                familyName: family.familyName, localizedName: family.localizedName, faces: faces)
        }
        facesByPostScriptName = loaded.flatMap(\.faces).reduce(into: [:]) { result, face in
            result[face.postScriptName] = face
        }
        revision &+= 1
    }

    private static func loadFamilies() -> [InstalledFontFamily] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.compactMap { availableFamily -> InstalledFontFamily? in
            guard !availableFamily.hasPrefix(".") else { return nil }
            var seen: Set<String> = []
            let faces = (manager.availableMembers(ofFontFamily: availableFamily) ?? []).compactMap {
                member -> InstalledFontFace? in
                guard member.count >= 4,
                    let postScriptName = member[0] as? String,
                    seen.insert(postScriptName).inserted,
                    let font = NSFont(name: postScriptName, size: 13)
                else { return nil }
                let descriptor = font.fontDescriptor
                let managerTraits = NSFontTraitMask(
                    rawValue: (member[3] as? NSNumber)?.uintValue ?? 0)
                let descriptorTraits = descriptor.symbolicTraits
                let familyName =
                    (CTFontCopyName(font as CTFont, kCTFontFamilyNameKey) as String?)
                    ?? font.familyName ?? availableFamily
                let localizedFamilyName =
                    localizedName(font, key: kCTFontFamilyNameKey)
                    ?? font.familyName ?? availableFamily
                let localizedFaceName =
                    localizedName(font, key: kCTFontStyleNameKey)
                    ?? (member[1] as? String) ?? postScriptName
                return InstalledFontFace(
                    postScriptName: postScriptName,
                    familyName: familyName,
                    localizedFamilyName: localizedFamilyName,
                    localizedFaceName: localizedFaceName,
                    cssWeight: cssWeight(for: descriptor),
                    italic: descriptorTraits.contains(.italic)
                        || managerTraits.contains(.italicFontMask),
                    monospaced: descriptorTraits.contains(.monoSpace)
                        || managerTraits.contains(.fixedPitchFontMask)
                )
            }
            .sorted {
                if $0.cssWeight != $1.cssWeight { return $0.cssWeight < $1.cssWeight }
                if $0.italic != $1.italic { return !$0.italic }
                return $0.localizedFaceName.localizedStandardCompare($1.localizedFaceName)
                    == .orderedAscending
            }
            guard let first = faces.first else { return nil }
            return InstalledFontFamily(
                familyName: first.familyName, localizedName: first.localizedFamilyName, faces: faces
            )
        }
        .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    private static func localizedName(_ font: NSFont, key: CFString) -> String? {
        CTFontCopyLocalizedName(font as CTFont, key, nil) as String?
    }

    private static func cssWeight(for descriptor: NSFontDescriptor) -> Int {
        let traits = descriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let rawWeight =
            (traits?[.weight] as? NSNumber)?.doubleValue ?? Double(NSFont.Weight.regular.rawValue)
        let candidates: [(Double, Int)] = [
            (Double(NSFont.Weight.ultraLight.rawValue), 100),
            (Double(NSFont.Weight.thin.rawValue), 200),
            (Double(NSFont.Weight.light.rawValue), 300),
            (Double(NSFont.Weight.regular.rawValue), 400),
            (Double(NSFont.Weight.medium.rawValue), 500),
            (Double(NSFont.Weight.semibold.rawValue), 600),
            (Double(NSFont.Weight.bold.rawValue), 700),
            (Double(NSFont.Weight.heavy.rawValue), 800),
            (Double(NSFont.Weight.black.rawValue), 900),
        ]
        return candidates.min { abs($0.0 - rawWeight) < abs($1.0 - rawWeight) }?.1 ?? 400
    }
}
