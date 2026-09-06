import Foundation
import Testing
@testable import SoyehtCore

/// Run by check-terminal-contract.py with both checkouts. The first phase
/// exports Swift's actual request; Rust executes it over HTTP/UDS/PTY and
/// exports the actual response and WebSocket frames for the second phase.
@Suite struct LocalTerminalCrossRepoTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOYEHT_TERMINAL_CONTRACT_DIR"] != nil))
    func crossRepoLocalTerminal() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SOYEHT_TERMINAL_CONTRACT_DIR"]))
        let stage = try #require(ProcessInfo.processInfo.environment["SOYEHT_TERMINAL_CONTRACT_STAGE"])
        let issued = try JSONDecoder().decode(SoyehtAPIClient.LocalTerminalIntent.self,
            from: Data(contentsOf: directory.appendingPathComponent("issued.json")))
        #expect(issued.backend == "supervisor")
        #expect(issued.conversationId == "supervised-pane")
        let issuedID = try #require(issued.intentId)
        #expect(UUID(uuidString: issuedID) != nil)
        if stage == "encode" {
            let request = SoyehtAPIClient.LocalTerminalCreateRequest(
                conversationId: "supervised-pane", argv: ["/bin/bash", "--noprofile", "--norc", "-i"],
                cwd: "/tmp", env: ["PS1": "", "PATH": "/usr/bin:/bin"], cols: 80, rows: 24,
                intentId: issuedID
            )
            let input = TerminalWireFrame.Input(data: "printf '\\143\\162\\157\\163\\163\\055\\142\\157\\165\\156\\144\\141\\162\\171\\055\\157\\153\\n'\n")
            try TerminalWireFrame.encoder.encode(input).write(to: directory.appendingPathComponent("input.json"), options: .atomic)
            try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request-ready.json"), options: .atomic)
            return
        }
        #expect(stage == "decode")
        struct Response: Decodable {
            let created: SoyehtAPIClient.LocalTerminalCreateResponse
            let restored: SoyehtAPIClient.LocalTerminalSessionMetadata
            let frames: [[UInt8]]
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("response.json"))
        let response = try JSONDecoder().decode(Response.self, from: data)
        let instance = try #require(response.created.sessionInstanceId)
        #expect(UUID(uuidString: instance) != nil)
        #expect(response.created.backend == "supervisor")
        #expect(response.created.streamProtocol == LocalTerminalStream.version)
        #expect(!response.created.reconnected)
        #expect(response.created.intentId == issuedID)
        #expect(response.restored.sessionInstanceId == instance)
        #expect(response.restored.isConnected)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attachedData = try JSONSerialization.data(withJSONObject: try #require(object["attached"]))
        let attached = try LocalTerminalStream.decodeControl(String(decoding: attachedData, as: UTF8.self))
        guard case .attached(let remoteInstance, _, _) = attached else {
            Issue.record("Rust did not emit the attached control event"); return
        }
        var cursor = LocalTerminalReplayCursor(instanceID: instance)
        try cursor.validate(instanceID: remoteInstance)
        var rendered = Data()
        #expect(!response.frames.isEmpty)
        for frame in response.frames {
            guard case .data(let offset, let bytes) = try LocalTerminalStream.decodeOutput(Data(frame)) else {
                Issue.record("Rust did not emit an output frame"); return
            }
            let accepted = try cursor.receive(offset: offset, bytes: bytes)
            rendered.append(accepted.bytes)
            try cursor.commit(offset: accepted.offset, byteCount: accepted.bytes.count)
        }
        #expect(rendered.range(of: Data("cross-boundary-ok".utf8)) != nil)
        #expect(cursor.applied == UInt64(rendered.count))
    }
}
