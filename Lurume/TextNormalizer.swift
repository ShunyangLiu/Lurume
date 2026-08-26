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
            } else {
                currentParagraph += " " + trimmedLine
            }
        }
        finishParagraph()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func collapseHorizontalWhitespace(in text: String) -> String {
        text.replacingOccurrences(
            of: #"[\t\u{00A0} ]+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func shouldJoinHyphenatedLine(_ current: String, nextLine: String) -> Bool {
        guard current.last == "-", let first = nextLine.first else { return false }
        return first.isLowercase
    }
}
