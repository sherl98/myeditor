import Foundation
import Observation

@Observable @MainActor
final class RecentDocuments {
    struct Entry: Codable, Identifiable {
        var path: String
        var bookmark: Data?
        var securityScoped: Bool?
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }
    private(set) var entries: [Entry]
    var expanded: Bool {
        didSet { defaults.set(expanded, forKey: "reader.recentsExpanded") }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored =
            defaults.data(forKey: "reader.recentDocuments").flatMap {
                try? JSONDecoder().decode([Entry].self, from: $0)
            } ?? []
        entries = Array(stored.prefix(5))
        expanded = defaults.object(forKey: "reader.recentsExpanded") as? Bool ?? true
    }

    func record(_ url: URL, replacing previous: URL? = nil) {
        let path = url.standardizedFileURL.path
        let previousEntry = entries.first {
            $0.path == path || $0.path == previous?.standardizedFileURL.path
        }
        entries.removeAll { $0.path == path || $0.path == previous?.standardizedFileURL.path }
        entries.insert(
            Entry(
                path: path, bookmark: previousEntry?.bookmark,
                securityScoped: previousEntry?.securityScoped), at: 0)
        entries = Array(entries.prefix(5))
        persist()
        // File Provider bookmark work must not block the window's main thread.
        Task { [weak self] in
            let bookmark = await Task.detached(priority: .utility) {
                () -> (data: Data, scoped: Bool)? in
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let data = try? url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                {
                    return (data, true)
                }
                // Non-sandboxed builds can retain the picker URL's implicit
                // grant. Keep the previous bookmark if File Provider is busy.
                if let data = try? url.bookmarkData(
                    options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                {
                    return (data, false)
                }
                return nil
            }.value
            guard let self, let bookmark,
                let index = self.entries.firstIndex(where: { $0.path == path })
            else { return }
            self.entries[index].bookmark = bookmark.data
            self.entries[index].securityScoped = bookmark.scoped
            self.persist()
        }
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        persist()
    }

    func resolve(_ entry: Entry) async -> URL {
        await Task.detached(priority: .utility) {
            if let data = entry.bookmark {
                var stale = false
                var options: URL.BookmarkResolutionOptions = [
                    .withoutUI, .withoutMounting, .withoutImplicitStartAccessing,
                ]
                if entry.securityScoped == true { options.insert(.withSecurityScope) }
                if let url = try? URL(
                    resolvingBookmarkData: data, options: options, relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                {
                    return url
                }
            }
            return entry.url
        }.value
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: "reader.recentDocuments")
        }
    }
}
