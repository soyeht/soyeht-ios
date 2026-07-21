import XCTest
@testable import SoyehtMacDomain

/// A2 acceptance: `env`/`cwd`/PATH inside the engine-broker pane must match
/// the `NativePTY` pane exactly. `EnginePaneSpawnRequestBuilder` reuses
/// `NativePTY.resolveSpawnPlan` under the hood, so these tests assert the
/// built request faithfully reflects the same plan `NativePTY.init` would
/// use to `execve` — without spawning a real process.
@MainActor
final class EnginePaneSpawnRequestBuilderTests: XCTestCase {
    private func makeConversation(handle: String = "foo") -> Conversation {
        Conversation(
            handle: handle,
            agent: .claw("claude"),
            workspaceID: UUID(),
            commander: .mirror(instanceID: "inst-1"),
            stats: .zero
        )
    }

    func testCwdMatchesResolvedPlanExactly() {
        let cwd = URL(fileURLWithPath: "/Users/mac-alpha/project")
        let conversation = makeConversation()
        let plan = NativePTY.resolveSpawnPlan(cwd: cwd, loginPath: "/usr/bin:/bin")
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: "/usr/bin:/bin",
            cols: 80,
            rows: 24
        )
        XCTAssertEqual(request.cwd, cwd.path)
        XCTAssertEqual(plan.env["PWD"], cwd.path)
    }

    func testPathAndTermMatchLoginResolvedPlanExactly() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let loginPath = "/opt/homebrew/bin:/usr/bin:/bin"
        let conversation = makeConversation()
        let plan = NativePTY.resolveSpawnPlan(cwd: cwd, loginPath: loginPath)
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: loginPath,
            cols: 80,
            rows: 24
        )
        let requestEnv = Dictionary(uniqueKeysWithValues: request.env.map { ($0[0], $0[1]) })
        XCTAssertEqual(requestEnv["PATH"], loginPath)
        XCTAssertEqual(requestEnv["PATH"], plan.env["PATH"])
        XCTAssertEqual(requestEnv["TERM"], "xterm-256color")
        XCTAssertEqual(requestEnv["TERM"], plan.env["TERM"])
        XCTAssertEqual(requestEnv["COLORTERM"], plan.env["COLORTERM"])
        XCTAssertEqual(requestEnv["SHELL"], plan.env["SHELL"])
    }

    func testAgentPaneEnvironmentInjectedIntoRequestEnv() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let conversation = makeConversation(handle: "bar")
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: nil,
            cols: 80,
            rows: 24
        )
        let requestEnv = Dictionary(uniqueKeysWithValues: request.env.map { ($0[0], $0[1]) })
        XCTAssertEqual(requestEnv[AgentPaneEnvironment.conversationIDKey], conversation.id.uuidString)
        XCTAssertEqual(requestEnv[AgentPaneEnvironment.handleKey], conversation.handle)
    }

    func testArgvExecutesTheFullyResolvedShellPath() {
        let cwd = URL(fileURLWithPath: "/tmp")
        let conversation = makeConversation()
        let plan = NativePTY.resolveSpawnPlan(cwd: cwd)
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: cwd,
            loginPath: nil,
            cols: 80,
            rows: 24
        )
        // The engine execs argv[0] directly (no separate exec-path vs
        // argv[0]-label split like `execve`), so argv[0] on the wire must be
        // the full shell path, not `plan.argv`'s cosmetic basename.
        XCTAssertEqual(request.argv.first, plan.shell)
        XCTAssertEqual(Array(request.argv.dropFirst()), Array(plan.argv.dropFirst()))
    }

    func testConversationIdMatchesUUID() {
        let conversation = makeConversation()
        let request = EnginePaneSpawnRequestBuilder.makeCreateRequest(
            conversation: conversation,
            cwd: URL(fileURLWithPath: "/tmp"),
            loginPath: nil,
            cols: 80,
            rows: 24
        )
        XCTAssertEqual(request.conversationId, conversation.id.uuidString)
    }
}
