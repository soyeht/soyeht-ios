import Foundation

struct UploadedAttachment: Decodable {
    let filename: String
    let kind: String
    let sizeBytes: Int
    let remotePath: String
    let uploadedAt: String
}

private struct AttachmentResponse: Decodable {
    let ok: Bool
    let attachment: UploadedAttachment
}

extension SoyehtAPIClient {

    /// Upload a local file to the claw's ~/Downloads via the backend.
    ///
    /// Streams the file in 64 KB chunks to a temp file to avoid loading
    /// large attachments into memory. Field order: session → kind → filename → file.
    func uploadAttachment(
        container: String,
        session: String,
        kind: AttachmentKind,
        localFileURL: URL,
        filename: String,
        mimeType: String? = nil
    ) async throws -> UploadedAttachment {
        guard let (token, host) = store.loadSession() else {
            throw APIError.noSession
        }

        let url = try buildURL(host: host, path: "/api/v1/terminals/\(container)/attachments")
        let boundary = "Boundary-\(UUID().uuidString)"

        // Build multipart body in a temp file using streaming to avoid
        // loading the entire file into memory.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        try buildMultipartBodyStreaming(
            boundary: boundary,
            session: session,
            kind: kind.rawValue,
            filename: filename,
            fileURL: localFileURL,
            mimeType: mimeType ?? "application/octet-stream",
            outputURL: tempURL
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 300 // 5 min for large uploads

        let (data, response) = try await self.session.upload(for: request, fromFile: tempURL)
        try checkResponse(response, data: data)

        let decoded = try decoder.decode(AttachmentResponse.self, from: data)
        return decoded.attachment
    }

    // MARK: - Streaming Multipart Builder

    /// Build a multipart/form-data body by streaming the file in chunks.
    /// Memory usage stays constant (~64 KB) regardless of file size.
    private func buildMultipartBodyStreaming(
        boundary: String,
        session: String,
        kind: String,
        filename: String,
        fileURL: URL,
        mimeType: String,
        outputURL: URL
    ) throws {
        guard let output = OutputStream(url: outputURL, append: false) else {
            throw APIError.invalidURL
        }
        output.open()
        defer { output.close() }

        // Field: session (must come first per contract)
        output.writeMultipartField(boundary: boundary, name: "session", value: session)

        // Field: kind
        output.writeMultipartField(boundary: boundary, name: "kind", value: kind)

        // Field: filename
        output.writeMultipartField(boundary: boundary, name: "filename", value: filename)

        // Field: file (binary, streamed in 64 KB chunks)
        let fileHeader = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        output.writeString(fileHeader)

        guard let input = InputStream(url: fileURL) else {
            throw APIError.invalidURL
        }
        input.open()
        defer { input.close() }

        let bufferSize = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while input.hasBytesAvailable {
            let bytesRead = input.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                output.write(buffer, maxLength: bytesRead)
            } else {
                break
            }
        }

        // Closing boundary
        output.writeString("\r\n--\(boundary)--\r\n")
    }
}

private extension OutputStream {
    func writeMultipartField(boundary: String, name: String, value: String) {
        writeString("--\(boundary)\r\n")
        writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        writeString("\(value)\r\n")
    }

    func writeString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            write(pointer, maxLength: rawBuffer.count)
        }
    }
}
