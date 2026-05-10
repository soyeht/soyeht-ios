import Foundation
import SoyehtCore

// CLI entry point for CI use.
// Usage: banned-vocab-audit path/to/A.xcstrings [path/to/B.xcstrings ...]
// Exit 0: no violations. Exit 1: violations found (printed to stdout).

let args = CommandLine.arguments.dropFirst()
guard !args.isEmpty else {
    fputs("usage: banned-vocab-audit <file.xcstrings> ...\n", stderr)
    exit(1)
}

let fileURLs = args.map { URL(fileURLWithPath: $0) }
let auditor = BannedVocabularyAuditor()

var allViolations: [BannedVocabularyViolation] = []
for url in fileURLs {
    do {
        let violations = try auditor.audit(fileURL: url)
        allViolations.append(contentsOf: violations)
    } catch {
        fputs("error reading \(url.path): \(error)\n", stderr)
        exit(1)
    }
}

if allViolations.isEmpty {
    print("banned-vocab-audit: OK — no banned terms found in \(fileURLs.count) file(s).")
    exit(0)
}

print("banned-vocab-audit: FAIL — \(allViolations.count) violation(s) found:\n")
for v in allViolations {
    print("  \(v.citation)")
    print("    term : \"\(v.matchedTerm)\"")
    print("    value: \"\(v.value)\"\n")
}
exit(1)
