import Foundation

extension SoyehtAPIClient {
    func capturePaneContent(
        container: String,
        session: String,
        paneId: String?,
        context: ServerContext
    ) async throws -> String {
        var queryItems = [URLQueryItem(name: "session", value: session)]
        if let paneId, !paneId.isEmpty {
            queryItems.append(URLQueryItem(name: "pane_id", value: sanitizePaneIdentifier(paneId)))
        }

        let (data, response) = try await authenticatedRequest(
            path: "/api/v1/terminals/\(container)/tmux/capture-pane",
            queryItems: queryItems,
            context: context
        )
        try checkResponse(response, data: data)

        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError(
                DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Cannot decode capture-pane response as UTF-8 text")
                )
            )
        }
        return text
    }

    func makePaneStreamWebSocketRequest(
        container: String,
        session: String,
        paneId: String,
        context: ServerContext
    ) throws -> URLRequest {
        try makeAuthenticatedWebSocketRequest(
            path: "/api/v1/terminals/\(container)/tmux/pane-stream",
            queryItems: [
                URLQueryItem(name: "session", value: session),
                URLQueryItem(name: "pane_id", value: sanitizePaneIdentifier(paneId)),
            ],
            context: context
        )
    }
}
