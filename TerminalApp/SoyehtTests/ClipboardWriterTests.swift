import Foundation
import Testing
import os
@testable import Soyeht

@Suite("ClipboardWriter", .serialized)
struct ClipboardWriterTests {
    private final class ClipboardBackendSpy: ClipboardWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [String] = []

        func writeString(_ value: String) {
            lock.lock()
            writes.append(value)
            lock.unlock()
        }

        var recordedWrites: [String] {
            lock.lock()
            defer { lock.unlock() }
            return writes
        }
    }

    private let logger = Logger(subsystem: "com.soyeht.mobile.tests", category: "clipboard")

    @Test("Valid UTF-8 clipboard payload is written")
    func writesValidUTF8Payload() async throws {
        let backend = ClipboardBackendSpy()

        ClipboardWriter.write(Data("hello from osc52".utf8), logger: logger, backend: backend)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(backend.recordedWrites == ["hello from osc52"])
    }

    @Test("Invalid UTF-8 clipboard payload is ignored")
    func ignoresInvalidUTF8Payload() async throws {
        let backend = ClipboardBackendSpy()

        ClipboardWriter.write(Data([0xFF, 0xFE, 0xFD]), logger: logger, backend: backend)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(backend.recordedWrites.isEmpty)
    }
}
