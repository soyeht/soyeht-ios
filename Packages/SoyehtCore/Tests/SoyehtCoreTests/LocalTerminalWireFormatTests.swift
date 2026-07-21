import Foundation
import Testing
@testable import SoyehtCore

/// Wire-format contract for `POST/DELETE /api/v1/terminals/local` — must
/// match theyos `admin/rust/server-rs/src/handlers_terminal.rs`
/// (`LocalTerminalCreateRequest`/`handle_local_terminal_create`) exactly:
/// snake_case keys, `env` as an array of `[key, value]` pairs (serde
/// serializes a `Vec<(String, String)>` tuple as a JSON array, not an
/// object), and a `{conversation_id, ws_path}` response shape.
@Suite struct LocalTerminalWireFormatTests {
    @Test("Create request encodes snake_case keys and env as pair-arrays")
    func createRequestWireShape() throws {
        let body = SoyehtAPIClient.LocalTerminalCreateRequest(
            conversationId: "conv-123",
            argv: ["/bin/bash", "-i"],
            cwd: "/Users/mac-alpha/project",
            env: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            cols: 80,
            rows: 24
        )
        let data = try JSONEncoder().encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["conversation_id"] as? String == "conv-123")
        #expect(json["argv"] as? [String] == ["/bin/bash", "-i"])
        #expect(json["cwd"] as? String == "/Users/mac-alpha/project")
        #expect(json["cols"] as? Int == 80)
        #expect(json["rows"] as? Int == 24)

        let env = try #require(json["env"] as? [[String]])
        let envDict = Dictionary(uniqueKeysWithValues: env.map { ($0[0], $0[1]) })
        #expect(envDict == ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
        for pair in env {
            #expect(pair.count == 2)
        }
    }

    @Test("Create request omits cwd key only when nil, never emits null noise otherwise")
    func createRequestNilCwd() throws {
        let body = SoyehtAPIClient.LocalTerminalCreateRequest(
            conversationId: "conv-456",
            argv: ["/bin/bash", "-i"],
            cwd: nil,
            env: [:],
            cols: 0,
            rows: 0
        )
        let data = try JSONEncoder().encode(body)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["cwd"] is NSNull || json["cwd"] == nil)
        #expect((json["env"] as? [[String]])?.isEmpty == true)
    }

    @Test("Create response decodes the engine's {conversation_id, ws_path} shape")
    func createResponseDecoding() throws {
        let json = """
        {"conversation_id":"conv-123","ws_path":"/api/v1/terminals/local/conv-123/pty"}
        """
        let response = try JSONDecoder().decode(
            SoyehtAPIClient.LocalTerminalCreateResponse.self,
            from: Data(json.utf8)
        )
        #expect(response.conversationId == "conv-123")
        #expect(response.wsPath == "/api/v1/terminals/local/conv-123/pty")
    }

    @Test("WebSocket attachment carries the token as a query param for .engine, cookie for .adminHost")
    func webSocketAttachmentKindBranching() {
        let engineServer = PairedServer(
            id: "srv-1",
            host: "localhost:8902",
            name: "local-engine",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .engine
        )
        let engineContext = ServerContext(server: engineServer, token: "tok-engine")
        let engineAttachment = SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment(
            conversationId: "conv-123",
            context: engineContext
        )
        #expect(engineAttachment.url.contains("token=tok-engine"))
        #expect(engineAttachment.url.contains("/api/v1/terminals/local/conv-123/pty"))
        #expect(engineAttachment.cookieHeader == nil)

        let adminServer = PairedServer(
            id: "srv-2",
            host: "linux-alpha.example.ts.net",
            name: "admin-host",
            role: nil,
            pairedAt: Date(),
            expiresAt: nil,
            kind: .adminHost
        )
        let adminContext = ServerContext(server: adminServer, token: "tok-admin")
        let adminAttachment = SoyehtAPIClient.shared.buildLocalTerminalWebSocketAttachment(
            conversationId: "conv-123",
            context: adminContext
        )
        #expect(!adminAttachment.url.contains("token="))
        #expect(adminAttachment.cookieHeader == "soyeht_session=tok-admin")
    }
}
