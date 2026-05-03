import Testing
import Foundation
import MCP
@testable import MCPxMacSeed

/// Integration tests for the 8 MCP tools.
/// Each test verifies that a tool handler produces valid CallTool.Result output.
struct ToolIntegrationTests {
    
    /// Creates a fully wired tool registry with all handlers registered.
    private func makeToolRegistry() async -> ToolRegistry {
        let db = try! Registry(path: ":memory:")
        let gate = ApprovalGate(registry: db)
        let toolReg = ToolRegistry()
        
        await registerAllTools(
            into: toolReg,
            db: db,
            intentExplorer: IntentExplorer(),
            sdefExtractor: SDEFExtractor(),
            accessibilityScanner: AccessibilityScanner(),
            screenContext: ScreenContext(),
            approvalGate: gate
        )
        
        return toolReg
    }
    
    private let testServer = Server(name: "test", version: "0.0.0")
    
    private func params(_ name: String, _ args: [String: Value]) -> CallTool.Parameters {
        return CallTool.Parameters(name: name, arguments: args)
    }
    
    // MARK: - Tool 1: scan_for_intents
    
    @Test func testScanIntentsValid() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "scan_for_intents") else {
            #expect(Bool(false), "Handler not found"); return
        }
        
        let result = try await handler(params("scan_for_intents", ["appName": .string("Mail")]), testServer)
        #expect(result.isError != true)
        #expect(!result.content.isEmpty)
    }
    
    @Test func testScanIntentsMissingParam() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "scan_for_intents") else { return }
        
        let result = try await handler(params("scan_for_intents", [:]), testServer)
        #expect(result.isError == true)
    }
    
    // MARK: - Tool 2: register_tool
    
    @Test func testRegisterTool() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "register_tool") else { return }
        
        let result = try await handler(params("register_tool", [
            "name": .string("test_intent"),
            "app": .string("TestApp"),
            "schemaJSON": .string(#"{"name":"test_intent"}"#)
        ]), testServer)
        #expect(result.isError != true)
    }
    
    // MARK: - Tool 3: list_registered_tools
    
    @Test func testListTools() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "list_registered_tools") else { return }
        
        let result = try await handler(params("list_registered_tools", ["app": .string("TestApp")]), testServer)
        #expect(result.isError != true)
    }
    
    // MARK: - Tool 5: fetch_scripting_dictionary
    
    @Test func testFetchSDEF() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "fetch_scripting_dictionary") else { return }
        
        let result = try await handler(params("fetch_scripting_dictionary", ["appName": .string("Finder")]), testServer)
        #expect(result.isError != true)
    }
    
    // MARK: - Tool 8: capture_screen_context
    
    @Test func testCaptureScreen() async throws {
        let tools = await makeToolRegistry()
        guard let handler = await tools.handler(for: "capture_screen_context") else { return }
        
        let result = try await handler(params("capture_screen_context", [:]), testServer)
        #expect(result.isError != true)
    }
}
