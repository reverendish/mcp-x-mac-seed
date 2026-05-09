import Foundation
import MCP

// MARK: - Server Bootstrap

/// Creates and starts the MCP-x-Mac Seed Server with all 8 tools and core modules wired.
func bootstrapServer() async throws {
    // ─── Initialize core modules ───
    
    // Database path: ~/Library/Application Support/MCPxMacSeed/tools.db
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dbDir = appSupport.appendingPathComponent("MCPxMacSeed")
    try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let dbPath = dbDir.appendingPathComponent("tools.db").path
    
    print("[MCPxMacSeed] Initializing Registry at \(dbPath)...")
    let db = try Registry(path: dbPath)
    
    print("[MCPxMacSeed] Initializing core modules...")
    let intentExplorer = IntentExplorer()
    let sdefExtractor = SDEFExtractor()
    let accessibilityScanner = AccessibilityScanner()
    let screenContext = ScreenContext()
    let approvalGate = ApprovalGate(registry: db)
    
    // ─── Run system bootstrap before starting server ───
    
    let bootstrap = SystemBootstrap(
        registry: db,
        sdefExtractor: sdefExtractor,
        intentExplorer: intentExplorer
    )
    let count = await bootstrap.bootstrapIfNeeded()
    if count > 0 {
        fputs("[MCPxMacSeed] Bootstrap complete: \(count) tools auto-discovered.\n", stderr)
    }
    
    // ─── Create tool registry and register all 8 seed tools ───
    
    let toolRegistry = ToolRegistry()
    await registerAllTools(
        into: toolRegistry,
        db: db,
        intentExplorer: intentExplorer,
        sdefExtractor: sdefExtractor,
        accessibilityScanner: accessibilityScanner,
        screenContext: screenContext,
        approvalGate: approvalGate
    )
    
    // ─── Create MCP Server ───
    
    let server = Server(
        name: "mcp-x-mac-seed",
        version: "0.1.0",
        capabilities: Server.Capabilities(
            tools: .init(listChanged: true)  // Dynamic tool set — list can change at runtime
        )
    )
    
    print("[MCPxMacSeed] Registering MCP method handlers...")
    
    // ─── tools/list handler ───
    await server.withMethodHandler(ListTools.self) { _ in
        let tools = await toolRegistry.allTools()
        print("[MCPxMacSeed] tools/list: returning \(tools.count) tool(s)")
        return ListTools.Result(tools: tools)
    }
    
    // ─── tools/call handler ───
    await server.withMethodHandler(CallTool.self) { callParams in
        guard let handler = await toolRegistry.handler(for: callParams.name) else {
            print("[MCPxMacSeed] tools/call: unknown tool '\(callParams.name)'")
            return CallTool.Result(
                content: [.text(
                    text: "Unknown tool: '\(callParams.name)'. Use list_registered_tools to see available tools.",
                    annotations: nil,
                    _meta: nil
                )],
                isError: true
            )
        }
        
        print("[MCPxMacSeed] tools/call: invoking '\(callParams.name)'...")
        let result = try await handler(callParams, server)
        print("[MCPxMacSeed] tools/call: '\(callParams.name)' returned \(result.content.count) content item(s)\(result.isError == true ? " (error)" : "")")
        return result
    }
    
    // ─── Start server on stdio ───
    
    print("[MCPxMacSeed] Starting server on stdio transport...")
    let transport = StdioTransport()
    
    do {
        try await server.start(transport: transport)
        print("[MCPxMacSeed] Server started. Waiting for connections...")
        
        // Keep alive until SIGTERM
        await server.waitUntilCompleted()
    } catch {
        print("[MCPxMacSeed] Server error: \(error)")
        throw error
    }
}
