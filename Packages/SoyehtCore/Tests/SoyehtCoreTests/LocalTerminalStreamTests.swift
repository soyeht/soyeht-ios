import Foundation
import Testing
@testable import SoyehtCore

@Suite struct LocalTerminalStreamTests {
    let instance = "00000000-0000-4000-8000-000000000001"

    @Test func reconnectReplaysBytesThatWereReceivedButNeverRendered() throws {
        var cursor = LocalTerminalReplayCursor(instanceID: instance)
        let queued = try cursor.receive(offset: 0, bytes: Data("abcdef".utf8))
        #expect(queued.bytes == Data("abcdef".utf8))
        try cursor.commit(offset: 0, byteCount: 2)
        #expect(cursor.applied == 2)
        #expect(cursor.received == 6)
        cursor.discardUnapplied()
        let replay = try cursor.receive(offset: 2, bytes: Data("cdef".utf8))
        #expect(replay.bytes == Data("cdef".utf8))
        try cursor.commit(offset: replay.offset, byteCount: replay.bytes.count)
        #expect(cursor.applied == 6)
        let duplicate = try cursor.receive(offset: 0, bytes: Data("abcdef".utf8))
        #expect(duplicate.bytes.isEmpty)
    }

    @Test func forwardJumpRequiresAnExplicitGapAndRendererAcknowledgement() throws {
        var cursor = LocalTerminalReplayCursor(instanceID: instance)
        #expect(throws: LocalTerminalStream.Failure.self) { try cursor.receive(offset: 100, bytes: Data([1])) }
        try cursor.receiveGap(from: 0, to: 100)
        #expect(cursor.applied == 0)
        try cursor.commitGap(from: 0, to: 100)
        let output = try cursor.receive(offset: 100, bytes: Data([0xff]))
        try cursor.commit(offset: output.offset, byteCount: output.bytes.count)
        #expect(cursor.applied == 101)
        #expect(throws: LocalTerminalStream.Failure.self) { try cursor.commit(offset: 101, byteCount: 1) }
    }

    @Test func binaryEnvelopePreservesRawBytesAndUsesMessageBoundaries() throws {
        var frame = LocalTerminalStream.outputPrefix
        frame.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 7])
        let payload = Data([0xff, 0xc3, 0]) + LocalTerminalStream.outputPrefix
        frame.append(payload)
        #expect(try LocalTerminalStream.decodeOutput(frame) == .data(offset: 7, bytes: payload))
        #expect(throws: LocalTerminalStream.Failure.self) { try LocalTerminalStream.decodeOutput(Data(frame.prefix(10))) }
        let overflow = LocalTerminalStream.outputPrefix + Data(repeating: 255, count: 9)
        #expect(throws: LocalTerminalStream.Failure.self) { try LocalTerminalStream.decodeOutput(overflow) }
    }

    @Test func controlsKeepSessionExitDistinctFromTransportFailure() throws {
        #expect(try LocalTerminalStream.decodeControl("{\"type\":\"error\",\"code\":\"input_delivery_uncertain\"}") == .error(code: "input_delivery_uncertain"))
        let exit = "{\"type\":\"exit\",\"session_instance_id\":\"\(instance)\",\"final_offset\":42,\"exit_code\":0,\"reason\":\"process_exited\"}"
        #expect(try LocalTerminalStream.decodeControl(exit) == .exited(instanceID: instance, finalOffset: 42, exitCode: 0, reason: "process_exited"))
        #expect(throws: (any Error).self) { try LocalTerminalStream.decodeControl("{\"type\":\"unknown_future_event\"}") }
        let cursor = LocalTerminalReplayCursor(instanceID: instance)
        #expect(throws: LocalTerminalStream.Failure.self) { try cursor.validate(instanceID: "00000000-0000-4000-8000-000000000002") }
    }
}
