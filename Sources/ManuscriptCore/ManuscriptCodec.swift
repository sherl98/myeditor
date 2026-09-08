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
    public static func revision(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sourceFromUTF8(_ data: Data) throws -> String {
        guard String(data: data, encoding: .utf8) != nil else { throw ManuscriptError.invalidUTF8 }
        return String(decoding: data, as: UTF8.self)
    }
    public static func editorSource(_ source: String) -> String {
        let text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }
    public static func encodedSource(_ text: String, matching original: String) -> String {
        let lineEnding = original.contains("\r\n") ? "\r\n" : "\n"
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
        while result.hasSuffix("\n") { result.removeLast() }
        if original.utf8.last == 0x0A, !result.isEmpty { result += "\n" }
        result = result.replacingOccurrences(of: "\n", with: lineEnding)
        return (original.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : "") + result
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
