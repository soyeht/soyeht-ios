import Foundation

/// Only top-level fields of one explicitly requested launchd job. Unknown or
/// incomplete output is not a snapshot and must not prove service absence.
struct LaunchdJobSnapshot: Codable, Equatable, Sendable {
    let path: String?
    let program: String
    let arguments: [String]
    let pid: UInt32?

    init?(output: String, domain: String, label: String, uid: UInt32) {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "\(domain)/\(uid)/\(label) = {" else { return nil }
        var depth = 1
        var collectingArguments = false
        var path: String?
        var program: String?
        var pid: UInt32?
        var argv: [String]?
        var sawPID = false
        for line in lines.dropFirst() {
            guard depth > 0 else { return nil }
            if line == "}" {
                depth -= 1
                collectingArguments = false
                continue
            }
            if collectingArguments && depth == 2 {
                argv?.append(line)
                continue
            }
            if depth == 1 {
                if line.hasPrefix("path = ") {
                    guard path == nil else { return nil }
                    path = String(line.dropFirst("path = ".count))
                } else if line.hasPrefix("program = ") {
                    guard program == nil else { return nil }
                    program = String(line.dropFirst("program = ".count))
                } else if line.hasPrefix("pid = ") {
                    guard !sawPID, let value = UInt32(line.dropFirst("pid = ".count)), value > 0 else { return nil }
                    sawPID = true
                    pid = value
                } else if line == "arguments = {" {
                    guard argv == nil else { return nil }
                    argv = []
                    collectingArguments = true
                }
            }
            if line.hasSuffix(" = {") { depth += 1 }
        }
        guard depth == 0, let program, let argv else { return nil }
        self.path = path
        self.program = program
        self.arguments = argv
        self.pid = pid
    }
}
