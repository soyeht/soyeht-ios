import Foundation
import SoyehtCore

/// Builds the `POST /api/v1/terminals/local` request body for a local agent
/// pane, reusing `NativePTY.resolveSpawnPlan` so the engine-broker path
/// (persistent panes) and the direct-`NativePTY` fallback path always spawn
/// byte-for-byte identical `argv`/`cwd`/`env` — the A2 acceptance bar.
enum EnginePaneSpawnRequestBuilder {
    static func makeCreateRequest(
        conversation: Conversation,
        cwd: URL,
        loginPath: String?,
        cols: Int,
        rows: Int
    ) -> SoyehtAPIClient.LocalTerminalCreateRequest {
        let plan = NativePTY.resolveSpawnPlan(
            shellPath: nil,
            cwd: cwd,
            loginPath: loginPath,
            extraEnvironment: AgentPaneEnvironment.values(for: conversation)
        )
        // `pty_process::Command::new(program)` (engine side) both resolves
        // and execs `argv[0]` directly — unlike `NativePTY`'s `execve`, it has
        // no separate "path to exec" vs "argv[0] label" concepts. Sending the
        // full shell path (rather than `plan.argv`'s cosmetic basename) keeps
        // the exec target unambiguous regardless of the engine's own PATH.
        let argv = [plan.shell] + plan.argv.dropFirst()
        return SoyehtAPIClient.LocalTerminalCreateRequest(
            conversationId: conversation.id.uuidString,
            argv: argv,
            cwd: cwd.path,
            env: plan.env,
            cols: cols,
            rows: rows
        )
    }
}
