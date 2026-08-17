import Foundation

enum OllamaQwenEmbeddingError: LocalizedError, Equatable {
    case daemonUnavailable
    case pinnedModelMissing
    case cloudRoutedModelRefused(String)
    case modelChangedDuringEmbedding
    case invalidResponse
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .daemonUnavailable:
            return "Local semantic search is waiting for Ollama. Text search remains available."
        case .pinnedModelMissing:
            return "The pinned local qwen3-embedding:4b model is not installed."
        case .cloudRoutedModelRefused(let model):
            return "Refused an embedding model without resident local weights: \(model)"
        case .modelChangedDuringEmbedding:
            return "The local embedding model changed while indexing; the batch was not stored."
        case .invalidResponse:
            return "Ollama returned an invalid embedding response."
        case .dimensionMismatch(let expected, let actual):
            return "Embedding dimension mismatch (expected \(expected), received \(actual))."
        }
    }
}

/// Local-only Qwen embedding client. The transport and model are deliberately
/// not configurable: a loopback Ollama daemon can itself route `:cloud` models
/// to the internet, so both boundaries must be enforced.
actor OllamaQwenEmbeddingClient {
    struct Configuration: Equatable, Sendable {
        let model: String
        let digest: String
        let dimensions: Int
    }

    static let pinnedModel = "qwen3-embedding:4b"
    static let dimensions = 512

    private static let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags")!
    private static let embedURL = URL(string: "http://127.0.0.1:11434/api/embed")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func configuration() async throws -> Configuration {
        do {
            let (data, response) = try await session.data(from: Self.tagsURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OllamaQwenEmbeddingError.daemonUnavailable
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]],
                  let model = models.first(where: {
                      ($0["name"] as? String) == Self.pinnedModel
                          || ($0["model"] as? String) == Self.pinnedModel
                  }) else {
                throw OllamaQwenEmbeddingError.pinnedModelMissing
            }
            let name = (model["name"] as? String) ?? (model["model"] as? String) ?? ""
            let size = (model["size"] as? NSNumber)?.int64Value ?? 0
            let digest = (model["digest"] as? String) ?? ""
            // A cloud-routed Ollama model has no resident weight size. Checking
            // loopback alone would therefore be a false locality guarantee.
            guard !name.lowercased().contains(":cloud"), size > 0 else {
                throw OllamaQwenEmbeddingError.cloudRoutedModelRefused(name)
            }
            guard !digest.isEmpty else { throw OllamaQwenEmbeddingError.invalidResponse }
            return Configuration(
                model: Self.pinnedModel,
                digest: digest,
                dimensions: Self.dimensions
            )
        } catch let error as OllamaQwenEmbeddingError {
            throw error
        } catch {
            throw OllamaQwenEmbeddingError.daemonUnavailable
        }
    }

    func embedPassages(_ passages: [String]) async throws -> (Configuration, [[Float]]) {
        let redacted = passages.map(ConversationIntelligencePrivacy.redactForEmbedding)
        return try await embed(redacted)
    }

    func embedQuery(_ query: String) async throws -> (Configuration, [Float]) {
        let redacted = ConversationIntelligencePrivacy.redactForEmbedding(query)
        let instructed = """
            Instruct: Given a user request, retrieve the most relevant prior conversation.
            Query: \(redacted)
            """
        let (configuration, vectors) = try await embed([instructed])
        guard let vector = vectors.first else { throw OllamaQwenEmbeddingError.invalidResponse }
        return (configuration, vector)
    }

    private func embed(_ input: [String]) async throws -> (Configuration, [[Float]]) {
        guard !input.isEmpty else { return (try await configuration(), []) }
        let configuration = try await configuration()
        let payload: [String: Any] = [
            "model": configuration.model,
            "input": input,
            "dimensions": configuration.dimensions,
            "keep_alive": "30m",
        ]
        var request = URLRequest(url: Self.embedURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawVectors = object["embeddings"] as? [[NSNumber]] else {
                throw OllamaQwenEmbeddingError.invalidResponse
            }
            let vectors = rawVectors.map { $0.map(\.floatValue) }
            for vector in vectors where vector.count != configuration.dimensions {
                throw OllamaQwenEmbeddingError.dimensionMismatch(
                    expected: configuration.dimensions,
                    actual: vector.count
                )
            }
            guard vectors.count == input.count else {
                throw OllamaQwenEmbeddingError.invalidResponse
            }
            let currentConfiguration = try await self.configuration()
            guard currentConfiguration == configuration else {
                throw OllamaQwenEmbeddingError.modelChangedDuringEmbedding
            }
            return (configuration, vectors)
        } catch let error as OllamaQwenEmbeddingError {
            throw error
        } catch {
            throw OllamaQwenEmbeddingError.daemonUnavailable
        }
    }
}
