import Testing
@testable import SoyehtCore

@Suite("Terminal process environment")
struct TerminalProcessEnvironmentTests {
    @Test("Interactive shells do not inherit Claude session-local state")
    func interactiveShellDropsClaudeSessionState() {
        let environment = TerminalProcessEnvironment.interactiveShellEnvironment(
            inherited: [
                "CLAUDECODE": "1",
                "CLAUDE_CODE_CHILD_SESSION": "1",
                "CLAUDE_CODE_ENTRYPOINT": "cli",
                "CLAUDE_CODE_EXECPATH": "/private/agent/claude",
                "CLAUDE_CODE_MESSAGING_SOCKET": "/private/agent/socket",
                "CLAUDE_CODE_MESSAGING_TOKEN": "secret",
                "CLAUDE_CODE_SESSION_ID": "old-session",
                "CLAUDE_PID": "1234",
                "CLAUDE_EFFORT": "high",
                "PATH": "/usr/bin:/bin",
            ],
            cwdPath: "/Users/test/project"
        )

        #expect(environment["CLAUDECODE"] == nil)
        #expect(environment["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(environment["CLAUDE_CODE_EXECPATH"] == nil)
        #expect(environment["CLAUDE_CODE_MESSAGING_SOCKET"] == nil)
        #expect(environment["CLAUDE_CODE_MESSAGING_TOKEN"] == nil)
        #expect(environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(environment["CLAUDE_PID"] == nil)
        #expect(environment["CLAUDE_EFFORT"] == "high")
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }
}
