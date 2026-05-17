import AppKit

struct GitRenderedDiff {
    let attributedText: NSAttributedString
    let hunkRanges: [NSRange]
    let stats: GitDiffStats
}

enum GitDiffRenderer {
    static func render(_ diff: String, showsLineNumbers: Bool) -> GitRenderedDiff {
        var hunkRanges: [NSRange] = []
        let stats = diffStats(for: diff)
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.lineBreakMode = .byClipping
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: GitPaneTypography.body(),
            .foregroundColor: GitPaneDesign.text,
            .paragraphStyle: paragraph,
        ]

        var oldLine: Int?
        var newLine: Int?
        diff.enumerateLines { line, _ in
            var attrs = baseAttrs
            var prefix: String?

            if line.hasPrefix("@@") {
                let rangeStart = output.length
                if let hunk = parseHunkHeader(line) {
                    oldLine = hunk.oldStart
                    newLine = hunk.newStart
                }
                attrs[.foregroundColor] = GitPaneDesign.hunkBlue
                attrs[.backgroundColor] = GitPaneDesign.hunkBackground
                hunkRanges.append(NSRange(location: rangeStart, length: (line as NSString).length))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                prefix = lineNumberPrefix(old: nil, new: newLine)
                newLine = newLine.map { $0 + 1 }
                attrs[.foregroundColor] = GitPaneDesign.greenText
                attrs[.backgroundColor] = GitPaneDesign.greenBackground
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                prefix = lineNumberPrefix(old: oldLine, new: nil)
                oldLine = oldLine.map { $0 + 1 }
                attrs[.foregroundColor] = GitPaneDesign.redText
                attrs[.backgroundColor] = GitPaneDesign.redBackground
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++") {
                attrs[.foregroundColor] = GitPaneDesign.yellow
            } else if oldLine != nil || newLine != nil {
                prefix = lineNumberPrefix(old: oldLine, new: newLine)
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    attrs[.foregroundColor] = GitPaneDesign.dim
                }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                attrs[.foregroundColor] = GitPaneDesign.dim
            }

            if !showsLineNumbers {
                prefix = nil
            }

            if let prefix {
                var prefixAttrs = attrs
                prefixAttrs[.foregroundColor] = GitPaneDesign.dim
                output.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
            }
            output.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }

        return GitRenderedDiff(
            attributedText: output,
            hunkRanges: hunkRanges,
            stats: stats
        )
    }

    private static func diffStats(for diff: String) -> GitDiffStats {
        var stats = GitDiffStats.empty
        diff.enumerateLines { line, _ in
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                stats.additions += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                stats.deletions += 1
            }
        }
        return stats
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        let parts = line.split(separator: " ")
        guard let oldToken = parts.first(where: { $0.hasPrefix("-") }),
              let newToken = parts.first(where: { $0.hasPrefix("+") }) else { return nil }
        let oldStart = oldToken.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        let newStart = newToken.dropFirst().split(separator: ",").first.flatMap { Int($0) }
        guard let oldStart, let newStart else { return nil }
        return (oldStart, newStart)
    }

    private static func lineNumberPrefix(old: Int?, new: Int?) -> String {
        "\(padded(old.map(String.init) ?? "")) \(padded(new.map(String.init) ?? ""))  "
    }

    private static func padded(_ string: String) -> String {
        String(repeating: " ", count: max(0, 4 - string.count)) + string
    }
}
