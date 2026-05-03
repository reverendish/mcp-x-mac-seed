import Foundation
import NaturalLanguage

// MARK: - Embedding Service

/// Generates text embeddings using Apple's NaturalLanguage framework.
/// Uses NLContextualEmbedding — on-device, private, zero network calls.
/// Mean-pools token vectors to produce a single embedding per text input.
actor EmbeddingService {
    
    private let model: NLContextualEmbedding
    let dimension: Int
    
    // MARK: - Init
    
    init() throws {
        guard let model = NLContextualEmbedding(language: .english) else {
            throw EmbeddingError.modelNotAvailable
        }
        
        // Ensure assets are available
        guard model.hasAvailableAssets else {
            throw EmbeddingError.modelNotAvailable
        }
        
        try model.load()
        self.model = model
        self.dimension = model.dimension
    }
    
    // MARK: - Public API
    
    /// Generates an embedding vector for the given text.
    /// Mean-pools all token vectors to produce a single [Float] representation.
    func embed(text: String) -> [Float] {
        let result = try? model.embeddingResult(for: text, language: nil)
        guard let result = result else {
            return []
        }
        
        // Mean-pool all token vectors into one embedding
        var pooled = [Double](repeating: 0, count: dimension)
        var tokenCount = 0
        
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, dimension) {
                pooled[i] += vector[i]
            }
            tokenCount += 1
            return true
        }
        
        guard tokenCount > 0 else { return [] }
        
        // Average
        return pooled.map { Float($0 / Double(tokenCount)) }
    }
    
    // MARK: - Cosine Similarity
    
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        
        return dotProduct / denominator
    }
}

// MARK: - Semantic Search

struct SemanticSearchResult: Codable, Sendable {
    let tool: ToolRecord
    let score: Float
}

// MARK: - Errors

enum EmbeddingError: Error, Equatable {
    case modelNotAvailable
    case modelLoadFailed
    case embeddingFailed(String)

    var localizedDescription: String {
        switch self {
        case .modelNotAvailable:
            return "NLContextualEmbedding model not available for English"
        case .modelLoadFailed:
            return "Failed to load the NL embedding model"
        case .embeddingFailed(let text):
            return "Failed to generate embedding for: '\(text.prefix(50))...'"
        }
    }
}

// MARK: - Registry Extensions for Semantic Search

extension Registry {
    
    func searchTools(query: String, limit: Int = 10) async throws -> [SemanticSearchResult] {
        let service = try EmbeddingService()
        let queryEmbedding = await service.embed(text: query)
        guard !queryEmbedding.isEmpty else { return [] }
        
        let allTools = try listTools(app: nil)
        
        var scored: [(tool: ToolRecord, score: Float)] = []
        
        for tool in allTools {
            let searchText = "\(tool.name) \(tool.app) \(extractDescription(tool.schemaJSON))"
            let toolVector = await service.embed(text: searchText)
            guard !toolVector.isEmpty else { continue }
            
            let score = EmbeddingService.cosineSimilarity(queryEmbedding, toolVector)
            if score > 0.1 {
                scored.append((tool, score))
            }
        }
        
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { SemanticSearchResult(tool: $0.tool, score: $0.score) }
    }
    
    private func extractDescription(_ schemaJSON: String) -> String {
        guard let data = schemaJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return schemaJSON
        }
        return (dict["description"] as? String) ?? schemaJSON
    }
}
