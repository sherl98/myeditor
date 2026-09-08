import AppKit
import Observation
import SwiftUI

enum ReaderAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum ReaderAccent: String, CaseIterable, Identifiable {
    case system, blue, green, yellow, pink, orange, purple, black

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "默认"
        case .blue: "蓝色"
        case .green: "绿色"
        case .yellow: "黄色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .purple: "紫色"
        case .black: "黑色"
        }
    }
    var nativeColor: NSColor? {
        switch self {
        case .system: nil
        case .blue: .systemBlue
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .pink: .systemPink
        case .orange: .systemOrange
        case .purple: .systemPurple
        case .black: .black
        }
    }
    var swatchColor: NSColor { nativeColor ?? .controlAccentColor }
    var swatchImage: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { bounds in
            swatchColor.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

@Observable @MainActor
final class ReaderPreferences {
    let fontCatalog: EditorFontCatalog
    var appearance: ReaderAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "reader.appearance")
            applyAppearance()
        }
    }
    var fontPercent: Int {
        didSet { UserDefaults.standard.set(fontPercent, forKey: "reader.fontPercent") }
    }
    var contentFont: EditorFontSelection {
        didSet { Self.store(contentFont, forKey: "reader.contentFont") }
    }
    var codeFont: EditorFontSelection {
        didSet { Self.store(codeFont, forKey: "reader.codeFont") }
    }
    var scale: CGFloat { CGFloat(fontPercent) / 100 }
    var fontSize: CGFloat { 21 * scale }
    var accentChoice: ReaderAccent {
        didSet {
            UserDefaults.standard.set(accentChoice.rawValue, forKey: "reader.accentChoice")
            refreshAccent()
        }
    }
    private(set) var accentHex = "#007AFF"
    private(set) var systemDarkAppearance = false
    @ObservationIgnored private var colorObserver: NSObjectProtocol?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?
    var accentColor: Color { Color(nsColor: nativeAccentColor) }
    var resolvedDarkAppearance: Bool {
        resolvedDark(for: appearance)
    }
    func resolvedDark(for appearance: ReaderAppearance) -> Bool {
        switch appearance {
        case .light: false
        case .dark: true
        case .system: systemDarkAppearance
        }
    }
    var nativeAccentColor: NSColor {
        let value = UInt32(accentHex.dropFirst(), radix: 16) ?? 0x007AFF
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static let minimumWindowSize = NSSize(width: 640, height: 640)

    init() {
        fontCatalog = EditorFontCatalog()
        systemDarkAppearance = Self.isDark(NSApp.effectiveAppearance)
        appearance =
            ReaderAppearance(
                rawValue: UserDefaults.standard.string(forKey: "reader.appearance") ?? "system")
            ?? .system
        let stored = UserDefaults.standard.integer(forKey: "reader.fontPercent")
        fontPercent = (80...140).contains(stored) && stored % 10 == 0 ? stored : 100
        contentFont = Self.storedFont(forKey: "reader.contentFont") ?? .systemDefault
        codeFont = Self.storedFont(forKey: "reader.codeFont") ?? .systemMonospaced
        if let storedChoice = UserDefaults.standard.string(forKey: "reader.accentChoice"),
            let choice = ReaderAccent(rawValue: storedChoice)
        {
            accentChoice = choice
        } else {
            accentChoice = Self.migratedAccent(
                from: UserDefaults.standard.string(forKey: "reader.accentHex"))
            UserDefaults.standard.set(accentChoice.rawValue, forKey: "reader.accentChoice")
        }
        refreshAccent()
        // Observe the resolved native appearance directly; system color
        // notifications alone need not arrive after the appearance has changed.
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.appearance == .system {
                    self.systemDarkAppearance = Self.isDark(NSApp.effectiveAppearance)
                }
                self.refreshAccent()
            }
        }
        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.appearance == .system {
                    self.systemDarkAppearance = Self.isDark(NSApp.effectiveAppearance)
                }
                self.refreshAccent()
            }
        }
    }

    func changeFont(by amount: Int) { fontPercent = min(140, max(80, fontPercent + amount)) }

    func applyAppearance() {
        let native: NSAppearance? =
            switch appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        NSApp.appearance = native
        if appearance == .system { systemDarkAppearance = Self.isDark(NSApp.effectiveAppearance) }
        refreshAccent()
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func refreshAccent() {
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = accentChoice.nativeColor ?? NSColor.controlAccentColor
            if let rgb = color.usingColorSpace(.sRGB) { accentHex = Self.hex(rgb) }
        }
    }

    private static func migratedAccent(from savedHex: String?) -> ReaderAccent {
        guard let savedHex,
            savedHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        else { return .system }
        return ReaderAccent.allCases.dropFirst().first { choice in
            guard let rgb = choice.nativeColor?.usingColorSpace(.sRGB) else { return false }
            return hex(rgb).caseInsensitiveCompare(savedHex) == .orderedSame
        } ?? .system
    }

    private static func hex(_ color: NSColor) -> String {
        String(
            format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    private static func storedFont(forKey key: String) -> EditorFontSelection? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EditorFontSelection.self, from: data)
    }

    private static func store(_ selection: EditorFontSelection, forKey key: String) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    var windowSize: NSSize {
        let width = UserDefaults.standard.double(forKey: "reader.windowWidth")
        let height = UserDefaults.standard.double(forKey: "reader.windowHeight")
        return NSSize(
            width: width > 0 ? max(Self.minimumWindowSize.width, width) : 1080,
            height: height > 0 ? max(Self.minimumWindowSize.height, height) : 800)
    }

    func rememberWindowSize(_ size: NSSize) {
        UserDefaults.standard.set(size.width, forKey: "reader.windowWidth")
        UserDefaults.standard.set(size.height, forKey: "reader.windowHeight")
    }
}
