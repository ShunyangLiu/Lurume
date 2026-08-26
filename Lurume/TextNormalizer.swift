import Foundation

enum TextNormalizer {
    static func translationInput(from rawText: String) -> String {
        let normalizedNewlines = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedNewlines.components(separatedBy: "\n")

        var paragraphs: [String] = []
        var currentParagraph = ""

        func finishParagraph() {
            let trimmed = collapseHorizontalWhitespace(in: currentParagraph)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paragraphs.append(trimmed)
            }
            currentParagraph = ""
        }

        for line in lines {
            let trimmedLine = collapseHorizontalWhitespace(in: line)
                .trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else {
                finishParagraph()
                continue
            }

            if currentParagraph.isEmpty {
                currentParagraph = trimmedLine
            } else if shouldJoinHyphenatedLine(currentParagraph, nextLine: trimmedLine) {
                currentParagraph.removeLast()
                currentParagraph += trimmedLine
            } else if joinsWithoutSpace(currentParagraph, nextLine: trimmedLine) {
                currentParagraph += trimmedLine
            } else {
                currentParagraph += " " + trimmedLine
            }
        }
        finishParagraph()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func collapseHorizontalWhitespace(in text: String) -> String {
        text.replacingOccurrences(
            of: #"[\t\x{00A0}\x{3000} ]+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func shouldJoinHyphenatedLine(_ current: String, nextLine: String) -> Bool {
        guard current.last == "-", let first = nextLine.first else { return false }
        return first.isLowercase
    }

    private static func joinsWithoutSpace(_ current: String, nextLine: String) -> Bool {
        guard let last = current.last, let first = nextLine.first else { return false }
        return isCJKCharacter(last) && isCJKCharacter(first)
    }

    // 韩文谚文不计入：韩文以空格分词，断行合并时应保留空格。
    private static func isCJKCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
