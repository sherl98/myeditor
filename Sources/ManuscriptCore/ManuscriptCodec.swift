import CryptoKit
import Foundation

public enum ManuscriptError: Error, LocalizedError, Equatable, Sendable {
    case invalidUTF8, sourceChanged, missingFile, notWritable, composing, closed, editorUnavailable
    case invalidName, nameInUse, operationInProgress
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: "文档不是有效的 UTF-8 文本。"
        case .sourceChanged: "源文件已在其他应用中更改，写回已暂停。"
        case .missingFile: "源文件已被移动或删除。当前内容仍保留，可以另存副本。"
        case .notWritable: "源文件或所在文件夹不可写。当前内容仍保留。"
        case .composing: "请先完成正在输入的文字。"
        case .closed: "文档已关闭。"
        case .editorUnavailable: "编辑器尚未完成同步，草稿已保留。请稍后重试。"
        case .invalidName: "请输入有效的文件名，不要包含斜杠、冒号或控制字符。"
        case .nameInUse: "同名文件已存在，请换一个名称。"
        case .operationInProgress: "请等待当前文档操作完成。"
        }
    }
}

public struct DocumentHeading: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let level: Int
    public let offset: Int
    public let characterCount: Int
    public init(id: String, title: String, level: Int, offset: Int, characterCount: Int = 0) {
        self.id = id
        self.title = title
        self.level = level
        self.offset = offset
        self.characterCount = characterCount
    }
}

/// Markdown structure is navigation metadata, never a condition for opening or saving a file.
public enum ManuscriptCodec {
    /// File name extensions opened as Markdown. New documents use `.md`.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    public static func isMarkdownFile(_ url: URL) -> Bool {
        url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public static func revision(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sourceFromUTF8(_ data: Data) throws -> String {
        guard let source = String(validating: data, as: UTF8.self) else {
            throw ManuscriptError.invalidUTF8
        }
        return source
    }

    /// File conventions the editor text does not carry. Scans UTF-8 bytes once;
    /// saving must not search a long document on the main thread.
    public struct SourceFormat: Equatable, Sendable {
        public let byteOrderMark: Bool
        public let crlf: Bool
        public let trailingNewline: Bool
        public init(_ source: String) {
            byteOrderMark = source.utf8.starts(with: [0xEF, 0xBB, 0xBF])
            var previous: UInt8 = 0
            var crlf = false
            for byte in source.utf8 {
                if byte == 0x0A, previous == 0x0D {
                    crlf = true
                    break
                }
                previous = byte
            }
            self.crlf = crlf
            trailingNewline = source.utf8.last == 0x0A
        }
    }

    public static func editorSource(_ source: String) -> String {
        let text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        return text.utf8.contains(0x0D) ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }
    /// The editor preserves the original trailing newlines of unedited text. A
    /// file that ended with a newline keeps at least one.
    public static func encodedSource(_ text: String, format: SourceFormat) -> String {
        var result =
            text.utf8.contains(0x0D) ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        if format.trailingNewline, !result.isEmpty, result.utf8.last != 0x0A { result += "\n" }
        if format.crlf { result = result.replacingOccurrences(of: "\n", with: "\r\n") }
        return format.byteOrderMark ? "\u{FEFF}" + result : result
    }
    public static func encodedSource(_ text: String, matching original: String) -> String {
        encodedSource(text, format: SourceFormat(original))
    }
    /// Byte equality. Files differ when their bytes differ, even if Swift would
    /// consider the strings canonically equivalent; it is also much faster.
    public static func sameText(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }
    public static func primaryHeadings(_ headings: [DocumentHeading]) -> [DocumentHeading] {
        guard let first = headings.first else { return [] }
        let candidates: [DocumentHeading]
        if headings.count > 1, first.level == 1, headings.filter({ $0.level == 1 }).count == 1 {
            candidates = Array(headings.dropFirst())
        } else {
            candidates = headings
        }
        guard let level = candidates.map(\.level).min() else { return [] }
        return candidates.filter { $0.level == level }
    }
    public static func characterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}
