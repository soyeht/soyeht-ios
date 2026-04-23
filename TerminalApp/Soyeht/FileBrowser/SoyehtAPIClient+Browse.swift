import Foundation

struct RemoteDirectoryEntry: Hashable {
    let name: String
    let path: String
    let kind: String
    let sizeBytes: Int?
    let modifiedAt: String?
    let permissions: String?

    var isDirectory: Bool {
        kind == "directory" || kind == "dir"
    }
}

struct RemoteDirectoryListing {
    let path: String
    let entries: [RemoteDirectoryEntry]
    let hasMore: Bool
    let nextCursor: String?
}

struct RemoteFilePreview {
    let path: String
    let mimeType: String
    let sizeBytes: Int
    let content: String
    let isTruncated: Bool
}

private struct FilesListPayload: Decodable {
    let path: String
    let entries: [Entry]
    let hasMore: Bool?
    let nextCursor: String?

    struct Entry: Decodable {
        let name: String
        let kind: String
        let size: Int?
        let modifiedAt: String?
        let permissions: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case kind
            case size
            case sizeBytes
            case modifiedAt
            case modified_at
            case permissions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            kind = try container.decode(String.self, forKey: .kind)
            size = try container.decodeIfPresent(Int.self, forKey: .size)
                ?? container.decodeIfPresent(Int.self, forKey: .sizeBytes)
            modifiedAt = try container.decodeIfPresent(String.self, forKey: .modifiedAt)
                ?? container.decodeIfPresent(String.self, forKey: .modified_at)
            permissions = try container.decodeIfPresent(String.self, forKey: .permissions)
        }
    }
}

private struct FilesListEnvelope: Decodable {
    let data: FilesListPayload
}

extension SoyehtAPIClient {
    func listRemoteDirectory(
        container: String,
        session: String,
        path: String? = nil,
        context: ServerContext
    ) async throws -> RemoteDirectoryListing {
        var queryItems = [URLQueryItem(name: "session", value: session)]
        if let path, !path.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: path))
        }

        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/terminals/\(container)/files",
            queryItems: queryItems,
            context: context
        )
        try checkResponse(response, data: data)
        return try parseRemoteDirectoryListing(data: data, requestedPath: path)
    }

    func loadRemoteFilePreview(
        container: String,
        session: String,
        path: String,
        maxBytes: Int = 524_288,
        knownFileSizeBytes: Int? = nil,
        context: ServerContext
    ) async throws -> RemoteFilePreview {
        let clampedMaxBytes = min(max(maxBytes, 1), 524_288)
        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/terminals/\(container)/files/read",
            queryItems: [
                URLQueryItem(name: "session", value: session),
                URLQueryItem(name: "path", value: path),
                URLQueryItem(name: "max_bytes", value: String(clampedMaxBytes)),
            ],
            context: context
        )
        try checkResponse(response, data: data)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Expected HTTPURLResponse")
                )
            )
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "File read response is not UTF-8 previewable")
                )
            )
        }

        let mimeType = httpResponse.mimeType ?? "text/plain"
        let isTruncated = knownFileSizeBytes.map { $0 > clampedMaxBytes } ?? (data.count == clampedMaxBytes)
        return RemoteFilePreview(
            path: path,
            mimeType: mimeType,
            sizeBytes: data.count,
            content: content,
            isTruncated: isTruncated
        )
    }

    func makeRemoteFileDownloadRequest(
        container: String,
        session: String,
        path: String,
        context: ServerContext
    ) throws -> URLRequest {
        try makeAuthenticatedURLRequest(
            path: "/api/v1/terminals/\(container)/files/download",
            queryItems: [
                URLQueryItem(name: "session", value: session),
                URLQueryItem(name: "path", value: path),
            ],
            context: context
        )
    }

    private func joinedRemotePath(base: String, child: String) -> String {
        if base == "/" {
            return "/\(child)"
        }
        if base.hasSuffix("/") {
            return "\(base)\(child)"
        }
        return "\(base)/\(child)"
    }

    private func parseRemoteDirectoryListing(
        data: Data,
        requestedPath: String?
    ) throws -> RemoteDirectoryListing {
        if let wrapped = try? decoder.decode(FilesListEnvelope.self, from: data) {
            return listing(from: wrapped.data)
        }
        if let bare = try? decoder.decode(FilesListPayload.self, from: data) {
            return listing(from: bare)
        }

        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            logFilesDecodeFailure(data: data, reason: "JSONSerialization failed: \(error.localizedDescription)")
            throw error
        }
        let fallbackPath = requestedPath ?? "~"

        let root: [String: Any]
        let entriesArray: [[String: Any]]
        let hasMore: Bool
        let nextCursor: String?

        switch rawObject {
        case let dict as [String: Any]:
            if let payload = dict["data"] as? [String: Any] {
                root = payload
                entriesArray = normalizedEntries(from: payload["entries"] ?? payload["data"])
                hasMore = boolValue(dict["has_more"]) ?? boolValue(payload["has_more"]) ?? false
                nextCursor = stringValue(dict["next_cursor"]) ?? stringValue(payload["next_cursor"])
            } else if let payload = dict["data"] as? [[String: Any]] {
                root = dict
                entriesArray = payload
                hasMore = boolValue(dict["has_more"]) ?? false
                nextCursor = stringValue(dict["next_cursor"])
            } else {
                root = dict
                entriesArray = normalizedEntries(from: dict["entries"] ?? dict["data"])
                hasMore = boolValue(dict["has_more"]) ?? false
                nextCursor = stringValue(dict["next_cursor"])
            }
        case let array as [[String: Any]]:
            root = [:]
            entriesArray = array
            hasMore = false
            nextCursor = nil
        default:
            logFilesDecodeFailure(data: data, reason: "Unsupported root type: \(type(of: rawObject))")
            throw APIError.decodingError(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Unsupported /files response shape")
                )
            )
        }

        let resolvedPath = stringValue(root["path"])
            ?? stringValue(root["current_path"])
            ?? stringValue(root["cwd"])
            ?? fallbackPath

        let entries = entriesArray.compactMap { entryDict -> RemoteDirectoryEntry? in
            let name = stringValue(entryDict["name"])
                ?? stringValue(entryDict["filename"])
                ?? stringValue(entryDict["basename"])
            guard let name, !name.isEmpty else { return nil }

            let fullPath = stringValue(entryDict["path"])
                ?? stringValue(entryDict["full_path"])
                ?? joinedRemotePath(base: resolvedPath, child: name)

            let kind = stringValue(entryDict["kind"])
                ?? stringValue(entryDict["type"])
                ?? ((boolValue(entryDict["is_directory"]) ?? false) ? "dir" : "file")

            return RemoteDirectoryEntry(
                name: name,
                path: fullPath,
                kind: kind,
                sizeBytes: intValue(entryDict["size"])
                    ?? intValue(entryDict["size_bytes"])
                    ?? intValue(entryDict["sizeBytes"]),
                modifiedAt: stringValue(entryDict["modified_at"])
                    ?? stringValue(entryDict["modifiedAt"])
                    ?? stringValue(entryDict["mtime"])
                    ?? stringValue(entryDict["last_modified"]),
                permissions: stringValue(entryDict["permissions"])
                    ?? stringValue(entryDict["perms"])
            )
        }

        return RemoteDirectoryListing(
            path: resolvedPath,
            entries: entries,
            hasMore: hasMore,
            nextCursor: nextCursor
        )
    }

    private func logFilesDecodeFailure(data: Data, reason: String) {
#if DEBUG
        let snippet = String(decoding: data.prefix(2048), as: UTF8.self)
        NSLog("[file-browser] /files decode failure: %@ body=%@", reason, snippet)
#endif
    }

    private func listing(from payload: FilesListPayload) -> RemoteDirectoryListing {
        let entries = payload.entries.map { entry in
            RemoteDirectoryEntry(
                name: entry.name,
                path: joinedRemotePath(base: payload.path, child: entry.name),
                kind: entry.kind,
                sizeBytes: entry.size,
                modifiedAt: entry.modifiedAt,
                permissions: entry.permissions
            )
        }

        return RemoteDirectoryListing(
            path: payload.path,
            entries: entries,
            hasMore: payload.hasMore ?? false,
            nextCursor: payload.nextCursor
        )
    }

    private func normalizedEntries(from value: Any?) -> [[String: Any]] {
        switch value {
        case let array as [[String: Any]]:
            return array
        case let dict as [String: Any]:
            if let nested = dict["entries"] as? [[String: Any]] {
                return nested
            }
            if let nested = dict["data"] as? [[String: Any]] {
                return nested
            }
            return []
        default:
            return []
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["true", "1", "yes"].contains(string.lowercased())
        default:
            return nil
        }
    }
}
