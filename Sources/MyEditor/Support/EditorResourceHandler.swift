import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled editor page and its code-split assets as
/// `myeditor-app://editor/…`. WebKit gets no file-system access; only files
/// inside the editor resource directory are readable.
@MainActor final class EditorResourceHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "myeditor-app"
    nonisolated static let pageURL = URL(string: "\(scheme)://editor/index.html")!

    /// The editor directory inside the app bundle. Debug builds run from the
    /// repository can also use the last Web build.
    nonisolated static let root: URL? = {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("EditorWeb")]
        #if DEBUG
            candidates.append(
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("EditorWeb/dist"))
        #endif
        return candidates.compactMap { $0?.standardizedFileURL }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
    }()

    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let requestURL = urlSchemeTask.request.url, let file = Self.file(for: requestURL)
        else {
            urlSchemeTask.didFailWithError(CocoaError(.fileNoSuchFile))
            return
        }
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            let read = Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }
            do {
                let data = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: {
                    read.cancel()
                }
                try Task.checkCancellation()
                urlSchemeTask.didReceive(
                    HTTPURLResponse(
                        url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": Self.contentType(for: file),
                            "Content-Length": "\(data.count)",
                            "Cache-Control": "no-cache",
                        ])!)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    /// Maps a request to a file below `root`; rejects other hosts and `..`.
    nonisolated static func file(for url: URL, root: URL? = root) -> URL? {
        guard url.scheme == scheme, url.host == "editor", let root else { return nil }
        let relative = url.path.drop { $0 == "/" }
        guard !relative.isEmpty else { return nil }
        let file = root.appendingPathComponent(String(relative)).standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }

    nonisolated static func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "txt": "text/plain; charset=utf-8"
        default:
            UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }
}
