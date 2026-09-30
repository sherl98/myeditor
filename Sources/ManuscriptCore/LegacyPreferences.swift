import Foundation

/// MyEditor 2.0 uses a new bundle identifier. Its first launch copies the
/// reader settings of earlier builds (`local.novelreader.app`) once.
public enum LegacyPreferences {
    public static let legacyDomain = "local.novelreader.app"
    static let marker = "migration.legacyDomain"

    /// Copies `reader.*` values that the current domain does not have yet.
    /// Returns the number of copied keys; runs at most once per domain.
    @discardableResult
    public static func migrate(from legacy: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: marker) == nil else { return 0 }
        defaults.set(legacyDomain, forKey: marker)
        var copied = 0
        for (key, value) in legacy ?? [:]
        where key.hasPrefix("reader.") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
