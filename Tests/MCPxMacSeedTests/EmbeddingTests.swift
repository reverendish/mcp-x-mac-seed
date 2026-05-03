import Testing
import Foundation
@testable import MCPxMacSeed

struct EmbeddingTests {
    
    // MARK: - Embedding Generation
    
    @Test("Generating an embedding returns a non-empty vector")
    func testEmbeddingGeneration() async throws {
        let service = try EmbeddingService()
        let vector = await service.embed(text: "send a message to Alice")
        
        #expect(!vector.isEmpty, "Embedding should not be empty")
        let dim = await service.dimension
        #expect(dim > 0, "Dimension must be positive")
        #expect(vector.count == dim)
    }
    
    @Test("Embeddings for similar texts are more similar than for different texts")
    func testSemanticSimilarity() async throws {
        let service = try EmbeddingService()
        
        let query = await service.embed(text: "send an email")
        let mail = await service.embed(text: "compose and send a mail message")
        let calculator = await service.embed(text: "perform arithmetic calculation")
        
        let mailSimilarity = EmbeddingService.cosineSimilarity(query, mail)
        let calcSimilarity = EmbeddingService.cosineSimilarity(query, calculator)
        
        #expect(mailSimilarity > calcSimilarity,
                "Mail text should be more similar than calculator (got mail=\(mailSimilarity), calc=\(calcSimilarity))")
    }
    
    @Test("Identical texts produce cosine similarity close to 1.0")
    func testIdenticalTexts() async throws {
        let service = try EmbeddingService()
        let a = await service.embed(text: "open the finder window")
        let b = await service.embed(text: "open the finder window")
        
        let similarity = EmbeddingService.cosineSimilarity(a, b)
        #expect(abs(similarity - 1.0) < 0.01, "Identical texts should have similarity ≈ 1.0, got \(similarity)")
    }
    
    // MARK: - Semantic Search
    
    @Test("Semantic search returns ranked results for a query")
    func testSemanticSearch() async throws {
        let registry = try Registry(path: ":memory:")
        
        try await registry.registerTool(
            name: "send_message",
            app: "Mail",
            schemaJSON: #"{"description":"Send an email message to a recipient"}"#,
            embedding: nil
        )
        try await registry.registerTool(
            name: "send_message",
            app: "Slack",
            schemaJSON: #"{"description":"Send a chat message to a Slack channel"}"#,
            embedding: nil
        )
        try await registry.registerTool(
            name: "calculate",
            app: "Calculator",
            schemaJSON: #"{"description":"Perform arithmetic operations"}"#,
            embedding: nil
        )
        try await registry.registerTool(
            name: "create_note",
            app: "Notes",
            schemaJSON: #"{"description":"Create a new note with text content"}"#,
            embedding: nil
        )
        
        let results = try await registry.searchTools(query: "send a message", limit: 3)
        
        #expect(!results.isEmpty, "Should return results")
        
        if results.count >= 1 {
            let topNames = results.prefix(min(2, results.count)).map { $0.tool.name }
            #expect(topNames.contains("send_message"),
                    "Top results should include send_message tools, got: \(topNames)")
        }
    }
    
    // MARK: - Cosine Similarity
    
    @Test("Cosine similarity of orthogonal vectors is 0")
    func testOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        
        let similarity = EmbeddingService.cosineSimilarity(a, b)
        #expect(abs(similarity) < 0.001)
    }
    
    @Test("Cosine similarity of empty vectors is 0")
    func testEmptyVectors() {
        let a: [Float] = []
        let b: [Float] = [1, 2, 3]
        
        let similarity = EmbeddingService.cosineSimilarity(a, b)
        #expect(similarity == 0)
    }
}
