import Foundation
import Testing
@testable import SoyehtCore

@Suite("ClawSiteHTTPCodec")
struct ClawSiteHTTPCodecTests {
    // MARK: - Request serialization

    @Test func serializesMinimalGetRequest() throws {
        let bytes = try ClawSiteHTTPCodec.serializeRequest(
            method: "get",
            path: "/index.html",
            host: "clawsite.local",
            headers: [:],
            body: nil
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text == """
        GET /index.html HTTP/1.1\r
        Host: clawsite.local\r
        Connection: close\r
        \r

        """)
    }

    @Test func emptyPathBecomesRoot() throws {
        let bytes = try ClawSiteHTTPCodec.serializeRequest(
            method: "GET", path: "", host: "h", headers: [:], body: nil
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.hasPrefix("GET / HTTP/1.1\r\n"))
    }

    @Test func stripsHopByHopAndCallerSuppliedHostAndConnection() throws {
        // A guest must not be able to smuggle a different Host (the tunnel,
        // not the header, decides which claw is reached) nor re-open the
        // connection semantics the response framing depends on.
        let bytes = try ClawSiteHTTPCodec.serializeRequest(
            method: "GET",
            path: "/",
            host: "clawsite.local",
            headers: [
                "Host": "evil.example",
                "Connection": "keep-alive",
                "Transfer-Encoding": "chunked",
                "Upgrade": "websocket",
                "Accept": "text/html",
            ],
            body: nil
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("Host: clawsite.local\r\n"))
        #expect(!text.contains("evil.example"))
        #expect(!text.lowercased().contains("keep-alive"))
        #expect(!text.lowercased().contains("upgrade:"))
        #expect(!text.lowercased().contains("transfer-encoding:"))
        #expect(text.contains("Accept: text/html\r\n"))
    }

    @Test func addsContentLengthForBodyAndAppendsIt() throws {
        let body = Data("name=soyeht".utf8)
        let bytes = try ClawSiteHTTPCodec.serializeRequest(
            method: "POST", path: "/submit", host: "h", headers: [:], body: body
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.hasSuffix("\r\n\r\nname=soyeht"))
    }

    @Test func omitsContentLengthForEmptyBody() throws {
        let bytes = try ClawSiteHTTPCodec.serializeRequest(
            method: "GET", path: "/", host: "h", headers: [:], body: Data()
        )
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.lowercased().contains("content-length"))
    }

    // MARK: - Response parsing

    @Test func parsesResponseWithContentLength() throws {
        let raw = Data("""
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: 5\r
        \r
        hello
        """.utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.statusCode == 200)
        #expect(response.httpVersion == "HTTP/1.1")
        #expect(response.headerValue("content-type") == "text/html; charset=utf-8")
        #expect(response.body == Data("hello".utf8))
    }

    @Test func contentLengthTruncatesTrailingBytes() throws {
        // Read-to-EOF can hand us more bytes than the response declares;
        // serving the extra as page content would be a corruption bug.
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloTRAILING".utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == Data("hello".utf8))
    }

    @Test func bodyRunsToEndWhenNoLengthOrEncoding() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nstreamed body".utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == Data("streamed body".utf8))
    }

    @Test func parsesChunkedBodyAndDropsTrailers() throws {
        // The bug this pins: treating a chunked body as opaque would render
        // "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n" into the page.
        let raw = Data("""
        HTTP/1.1 200 OK\r
        Content-Type: text/plain\r
        Transfer-Encoding: chunked\r
        \r
        5\r
        hello\r
        6\r
         world\r
        0\r
        X-Trailer: ignored\r
        \r

        """.utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == Data("hello world".utf8))
    }

    @Test func chunkedWinsOverContentLength() throws {
        // RFC 9110: when both are present, Transfer-Encoding governs. A server
        // that sends both and a parser that trusts Content-Length would slice
        // the chunk framing into the body.
        let raw = Data("""
        HTTP/1.1 200 OK\r
        Content-Length: 99\r
        Transfer-Encoding: chunked\r
        \r
        4\r
        okay\r
        0\r
        \r

        """.utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == Data("okay".utf8))
    }

    @Test func parsesChunkExtensions() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;name=value\r\nabc\r\n0\r\n\r\n".utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == Data("abc".utf8))
    }

    @Test func parsesBinaryBodyWithoutCorruption() throws {
        // Bytes that are not valid UTF-8 must survive: images and fonts are
        // exactly what a shared app serves alongside its HTML.
        var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\n\r\n".utf8)
        let payload = Data([0x89, 0x50, 0xFF, 0x00])
        raw.append(payload)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.body == payload)
    }

    @Test func preservesRepeatedHeadersAndJoinsThemForHeaderFields() throws {
        let raw = Data("""
        HTTP/1.1 200 OK\r
        Set-Cookie: a=1\r
        Set-Cookie: b=2\r
        Content-Length: 0\r
        \r

        """.utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.headers.filter { $0.name == "Set-Cookie" }.count == 2)
        #expect(response.headerFields["Set-Cookie"] == "a=1, b=2")
    }

    @Test func parsesNonOkStatusCodes() throws {
        let raw = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(raw)
        #expect(response.statusCode == 404)
        #expect(response.body.isEmpty)
    }

    @Test func rejectsHeaderlessAndMalformedResponses() throws {
        // No CRLFCRLF at all — the response never completed.
        #expect(throws: ClawSiteHTTPCodec.CodecError.responseHeaderIncomplete) {
            _ = try ClawSiteHTTPCodec.parseResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 0".utf8))
        }
        // Not HTTP at all — e.g. a PTY stream mistakenly routed here.
        #expect(throws: ClawSiteHTTPCodec.CodecError.responseStatusLineMalformed) {
            _ = try ClawSiteHTTPCodec.parseResponse(Data("bash: command not found\r\n\r\n".utf8))
        }
        // Status code outside the valid range.
        #expect(throws: ClawSiteHTTPCodec.CodecError.responseStatusLineMalformed) {
            _ = try ClawSiteHTTPCodec.parseResponse(Data("HTTP/1.1 999999 Nope\r\n\r\n".utf8))
        }
    }

    @Test func rejectsTruncatedChunkedBody() throws {
        // Declares 10 bytes, delivers 3, never terminates: must fail rather
        // than silently render a partial page as if it were complete.
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\na\r\nabc".utf8)
        #expect(throws: ClawSiteHTTPCodec.CodecError.responseChunkMalformed) {
            _ = try ClawSiteHTTPCodec.parseResponse(raw)
        }
    }

    @Test func rejectsChunkedBodyMissingTerminalChunk() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n".utf8)
        #expect(throws: ClawSiteHTTPCodec.CodecError.responseChunkMalformed) {
            _ = try ClawSiteHTTPCodec.parseResponse(raw)
        }
    }

    @Test func roundTripsAgainstTheFriendCliWireShape() throws {
        // friend-cli's ClawSite smoke writes exactly this request and the
        // engine-side test double replies with exactly this response. Pinning
        // both ends here means a change to our codec that breaks interop with
        // the already-proven Rust path fails locally, not on a device.
        let request = try ClawSiteHTTPCodec.serializeRequest(
            method: "GET", path: "/", host: "clawsite.local", headers: [:], body: nil
        )
        #expect(String(data: request, encoding: .utf8)
            == "GET / HTTP/1.1\r\nHost: clawsite.local\r\nConnection: close\r\n\r\n")

        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let response = try ClawSiteHTTPCodec.parseResponse(reply)
        #expect(response.statusCode == 200)
        #expect(response.body == Data("hello".utf8))
    }
}
