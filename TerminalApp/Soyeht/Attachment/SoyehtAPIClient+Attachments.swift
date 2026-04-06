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
    /// Builds a multipart/form-data body in a temp file to avoid loading
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

        // Build multipart body in a temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).multipart")
        let bodyData = try buildMultipartBody(
            boundary: boundary,
            session: session,
            kind: kind.rawValue,
            filename: filename,
            fileURL: localFileURL,
            mimeType: mimeType ?? "application/octet-stream"
        )
        try bodyData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 300 // 5 min for large uploads

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL)
        try checkResponse(response, data: data)

        let decoded = try decoder.decode(AttachmentResponse.self, from: data)
        return decoded.attachment
    }

    // MARK: - Multipart Builder

    private func buildMultipartBody(
        boundary: String,
        session: String,
        kind: String,
        filename: String,
        fileURL: URL,
        mimeType: String
    ) throws -> Data {
        var body = Data()

        // Field: session (must come first per contract)
        body.appendMultipartField(boundary: boundary, name: "session", value: session)

        // Field: kind
        body.appendMultipartField(boundary: boundary, name: "kind", value: kind)

        // Field: filename
        body.appendMultipartField(boundary: boundary, name: "filename", value: filename)

        // Field: file (binary)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n".data(using: .utf8)!)

        // Closing boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }
}

private extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
