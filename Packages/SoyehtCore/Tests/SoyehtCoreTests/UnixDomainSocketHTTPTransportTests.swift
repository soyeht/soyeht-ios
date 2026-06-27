import Foundation
import Testing

@testable import SoyehtCore

@Suite struct UnixDomainSocketHTTPTransportTests {
    @Test func serializeUsesDeterministicHTTP11ContentLengthAndClose() throws {
        var request = URLRequest(url: URL(string: "http://soyeht-local:8892/api/v1/local/enroll/start?mode=mac")!)
        request.httpMethod = "POST"
        request.setValue(BootstrapWire.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(BootstrapWire.contentType, forHTTPHeaderField: "Accept")
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        request.httpBody = Data([0xa1, 0x61, 0x76, 0x01])

        let wire = try UnixDomainSocketHTTPFraming.serialize(request: request)
        let delimiter = Data([13, 10, 13, 10])
        let headerRange = try #require(wire.range(of: delimiter))
        let text = try #require(String(data: wire[..<headerRange.lowerBound], encoding: .utf8))

        #expect(text.hasPrefix("POST /api/v1/local/enroll/start?mode=mac HTTP/1.1"))
        #expect(text.contains("Accept: \(BootstrapWire.contentType)"))
        #expect(text.contains("Connection: close"))
        #expect(text.contains("Content-Length: 4"))
        #expect(text.contains("Content-Type: \(BootstrapWire.contentType)"))
        #expect(text.contains("Host: soyeht-local:8892"))
        #expect(!text.contains("Transfer-Encoding"))
        #expect(Data(wire.suffix(4)) == Data([0xa1, 0x61, 0x76, 0x01]))
    }

    @Test func parseResponseRequiresContentLengthAndReturnsHTTPResponse() throws {
        let url = URL(string: "http://soyeht-local/api/v1/local/enroll/status")!
        let body = Data([0xa2, 0x61, 0x76, 0x01, 0x68, 0x65, 0x6e, 0x72, 0x6f, 0x6c, 0x6c, 0x65, 0x64, 0xf4])
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(BootstrapWire.contentType)\r\nContent-Length: \(body.count)\r\n\r\n"
        var wire = Data(header.utf8)
        wire.append(body)

        let maybeParsed = try UnixDomainSocketHTTPFraming.parseResponse(wire, url: url)
        let parsed = try #require(maybeParsed)
        let response = try #require(parsed.1 as? HTTPURLResponse)

        #expect(parsed.0 == body)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == BootstrapWire.contentType)
    }

    @Test func parseResponseRejectsChunkedOrMissingContentLength() throws {
        let url = URL(string: "http://soyeht-local/api/v1/local/enroll/status")!
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
        let missingLength = Data("HTTP/1.1 200 OK\r\nContent-Type: \(BootstrapWire.contentType)\r\n\r\n".utf8)
        let oversizedLength = Data("HTTP/1.1 200 OK\r\nContent-Length: \(UnixDomainSocketHTTPTransport.maximumResponseBodyBytes + 1)\r\n\r\n".utf8)

        #expect(throws: BootstrapError.protocolViolation(detail: .unexpectedResponseShape)) {
            _ = try UnixDomainSocketHTTPFraming.parseResponse(chunked, url: url)
        }
        #expect(throws: BootstrapError.protocolViolation(detail: .unexpectedResponseShape)) {
            _ = try UnixDomainSocketHTTPFraming.parseResponse(missingLength, url: url)
        }
        #expect(throws: BootstrapError.protocolViolation(detail: .unexpectedResponseShape)) {
            _ = try UnixDomainSocketHTTPFraming.parseResponse(oversizedLength, url: url)
        }
    }

    @Test func bufferedResponseSizeRejectsOversizedHeadersWithoutDelimiter() throws {
        let headerPrefix = Data(repeating: UInt8(ascii: "A"), count: UnixDomainSocketHTTPTransport.maximumResponseBodyBytes + 1)

        #expect(throws: BootstrapError.protocolViolation(detail: .unexpectedResponseShape)) {
            try UnixDomainSocketHTTPFraming.validateBufferedResponseSize(headerPrefix)
        }
    }

    @Test func sourceUsesUnixEndpointAndDoesNotUseURLSession() throws {
        let transportSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SoyehtCore/Networking/UnixDomainSocketHTTPTransport.swift")
        let transportSource = try String(contentsOf: transportSourceURL, encoding: .utf8)

        #expect(transportSource.contains("NWConnection(to: .unix(path: socketPath), using: .tcp)"))
        #expect(!transportSource.contains("URLSession"))
    }
}
