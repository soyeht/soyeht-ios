import Foundation

/// Removes Swift comments from source while preserving the surrounding code and
/// line breaks, so the source-slice guards (`ClawRouteUsageTests`,
/// `LegacyBoundaryUsageTests`) match only real code.
///
/// Handles `//` line/trailing comments and `/* ... */` block comments, including
/// Swift's nested block comments. Unlike the previous line-prefix heuristic, a
/// trailing `// comment` no longer hides (or reveals) the code on its own line,
/// and a block comment whose interior lines do not start with `*` is still
/// stripped.
///
/// Out of scope (unchanged from the prior scanner): string-literal contents are
/// NOT special-cased, so a token inside a `"..."` literal stays visible.
enum SourceCommentStripper {
    static func strip(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        result.reserveCapacity(chars.count)

        var i = 0
        var inLineComment = false
        var blockDepth = 0

        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

            if inLineComment {
                // Consume until end of line; keep the newline so lines never merge.
                if c == "\n" {
                    inLineComment = false
                    result.append(c)
                }
                i += 1
            } else if blockDepth > 0 {
                if c == "/" && next == "*" {
                    blockDepth += 1           // nested block opens
                    i += 2
                } else if c == "*" && next == "/" {
                    blockDepth -= 1           // block (or nesting level) closes
                    i += 2
                } else {
                    if c == "\n" { result.append(c) }  // preserve line breaks in blocks
                    i += 1
                }
            } else if c == "/" && next == "/" {
                inLineComment = true
                i += 2
            } else if c == "/" && next == "*" {
                blockDepth += 1
                i += 2
            } else {
                result.append(c)
                i += 1
            }
        }

        return result
    }
}
