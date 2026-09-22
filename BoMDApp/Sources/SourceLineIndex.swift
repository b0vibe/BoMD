import Foundation

/// Immutable per-document index. AppKit character offsets are UTF-16, not
/// Swift Character counts. Rebuild only when the source changes.
final class SourceLineIndex {
    private let lines: [String]
    private let starts: [Int]
    private let headings: [Bool]
    private let length: Int

    private static let headingPattern = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}\s+\S"#)
    private static let underlinePattern = try! NSRegularExpression(pattern: #"^ {0,3}(=+|-+)\s*$"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)
    private static let listPattern = try! NSRegularExpression(pattern: #"^([-+*]|\d+[.)])\s+\S"#)

    init(_ source: String) {
        let lines = source.components(separatedBy: "\n")
        self.lines = lines
        var starts = [0]
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        self.starts = starts
        length = offset

        var headings = [Bool](repeating: false, count: lines.count)
        var openingMarker: Character?
        for (index, text) in lines.enumerated() {
            if openingMarker == nil {
                headings[index] = Self.matches(Self.headingPattern, text)
                    || (index + 1 < lines.count
                        && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && Self.matches(Self.underlinePattern, lines[index + 1]))
            }
            // Preserve the existing fence/heading interpretation; compute it
            // once instead of scanning the whole prefix for each visible line.
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = Self.fencePattern.firstMatch(in: text, range: range) {
                let marker = (text as NSString).substring(with: match.range)
                    .trimmingCharacters(in: .whitespaces).first
                if openingMarker == nil { openingMarker = marker }
                else if openingMarker == marker { openingMarker = nil }
            }
        }
        self.headings = headings
    }

    func isHeadingLine(_ line: Int) -> Bool {
        guard line > 0, line <= headings.count else { return false }
        return headings[line - 1]
    }

    func anchorKind(for line: Int) -> String {
        guard line > 0, line <= lines.count else { return "content" }
        let text = lines[line - 1].trimmingCharacters(in: .whitespaces)
        if text.contains("|") { return "table" }
        if text.hasPrefix("$$") || text.hasPrefix("\\[") { return "math" }
        if text.hasPrefix("```") || text.hasPrefix("~~~") { return "code" }
        if Self.matches(Self.listPattern, text) { return "list" }
        return "content"
    }

    func characterOffset(for line: Int) -> Int {
        guard line > 1 else { return 0 }
        guard line <= starts.count else { return length }
        return starts[line - 1]
    }

    func lineNumber(atUTF16Offset offset: Int) -> Int {
        let target = min(max(0, offset), length)
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= target { lower = middle + 1 }
            else { upper = middle }
        }
        return max(1, lower)
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}
