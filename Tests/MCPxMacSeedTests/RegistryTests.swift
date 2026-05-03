import Testing
import Foundation
@testable import MCPxMacSeed

struct RegistryTests {
    
    // MARK: - Register Tool
    
    @Test("Registering a tool creates a record and returns a valid ID")
    func testRegisterToolCreatesRecord() async throws {
        let registry = try Registry(path: ":memory:")
        let schema = #"{"name":"send_message","description":"Send a message"}"#
        
        let id = try await registry.registerTool(
            name: "send_message",
            app: "Mail",
            schemaJSON: schema,
            embedding: nil
        )
        
        #expect(id > 0)
        
        let record = try await registry.getTool(id: id)
        #expect(record != nil)
        #expect(record?.name == "send_message")
        #expect(record?.app == "Mail")
        #expect(record?.status == "active")
        #expect(record?.requiresApproval == false)
        #expect(record?.version == 1)
    }
    
    @Test("Registering the same app+name twice updates the existing record (upsert)")
    func testRegisterToolUpsertOnConflict() async throws {
        let registry = try Registry(path: ":memory:")
        let schema1 = #"{"name":"send_message","description":"v1"}"#
        let schema2 = #"{"name":"send_message","description":"v2"}"#
        
        let id1 = try await registry.registerTool(
            name: "send_message",
            app: "Mail",
            schemaJSON: schema1,
            embedding: nil
        )
        
        let id2 = try await registry.registerTool(
            name: "send_message",
            app: "Mail",
            schemaJSON: schema2,
            embedding: nil
        )
        
        #expect(id1 == id2, "Upsert should return the same ID")
        
        let record = try await registry.getTool(id: id1)
        #expect(record?.schemaJSON == schema2, "Schema should be updated to v2")
        #expect(record?.version == 2, "Version should increment on update")
    }
    
    @Test("Registering tool with embedding stores it without error")
    func testRegisterToolWithEmbedding() async throws {
        let registry = try Registry(path: ":memory:")
        let schema = #"{"name":"test_tool"}"#
        let embedding: [Float] = Array(repeating: 0.1, count: 8)
        
        let id = try await registry.registerTool(
            name: "test_tool",
            app: "TestApp",
            schemaJSON: schema,
            embedding: embedding
        )
        
        #expect(id > 0)
        // Embedding storage verified in Phase 10; for now just confirm no crash
    }
    
    // MARK: - List Tools
    
    @Test("Listing tools returns all registered tools across all apps")
    func testListToolsAllApps() async throws {
        let registry = try Registry(path: ":memory:")
        
        try await registry.registerTool(name: "t1", app: "AppA", schemaJSON: "{}", embedding: nil)
        try await registry.registerTool(name: "t2", app: "AppB", schemaJSON: "{}", embedding: nil)
        try await registry.registerTool(name: "t3", app: "AppA", schemaJSON: "{}", embedding: nil)
        
        let tools = try await registry.listTools(app: nil)
        #expect(tools.count == 3)
    }
    
    @Test("Listing tools filtered by app returns only that app's tools")
    func testListToolsFilterByApp() async throws {
        let registry = try Registry(path: ":memory:")
        
        try await registry.registerTool(name: "t1", app: "AppA", schemaJSON: "{}", embedding: nil)
        try await registry.registerTool(name: "t2", app: "AppB", schemaJSON: "{}", embedding: nil)
        
        let appATools = try await registry.listTools(app: "AppA")
        #expect(appATools.count == 1)
        #expect(appATools[0].app == "AppA")
        
        let appBTools = try await registry.listTools(app: "AppB")
        #expect(appBTools.count == 1)
        #expect(appBTools[0].app == "AppB")
    }
    
    @Test("Listing tools on an empty registry returns empty array")
    func testListToolsEmptyRegistry() async throws {
        let registry = try Registry(path: ":memory:")
        let tools = try await registry.listTools(app: nil)
        #expect(tools.isEmpty)
    }
    
    // MARK: - Get Tool
    
    @Test("Getting a tool by ID returns the correct record")
    func testGetToolExists() async throws {
        let registry = try Registry(path: ":memory:")
        let id = try await registry.registerTool(
            name: "find_tool",
            app: "Finder",
            schemaJSON: #"{"test":true}"#,
            embedding: nil
        )
        
        let record = try await registry.getTool(id: id)
        #expect(record != nil)
        #expect(record?.id == id)
        #expect(record?.name == "find_tool")
        #expect(record?.schemaJSON == #"{"test":true}"#)
    }
    
    @Test("Getting a tool by non-existent ID returns nil")
    func testGetToolNotFound() async throws {
        let registry = try Registry(path: ":memory:")
        let record = try await registry.getTool(id: 99999)
        #expect(record == nil)
    }
    
    // MARK: - Update Tool Status (Repairman)
    
    @Test("Updating tool status sets error and appends to repair history")
    func testUpdateToolStatusSetsError() async throws {
        let registry = try Registry(path: ":memory:")
        let schema = #"{"name":"broken_tool"}"#
        let id = try await registry.registerTool(
            name: "broken_tool",
            app: "Test",
            schemaJSON: schema,
            embedding: nil
        )
        
        try await registry.updateToolStatus(
            id: id,
            status: "broken",
            error: #"{"code":"PARAM_MISSING","field":"subject"}"#
        )
        
        let record = try await registry.getTool(id: id)
        #expect(record?.status == "broken")
        #expect(record?.lastError == #"{"code":"PARAM_MISSING","field":"subject"}"#)
    }
    
    @Test("Repair history appends entries on multiple status updates")
    func testUpdateToolStatusAppendsRepairHistory() async throws {
        let registry = try Registry(path: ":memory:")
        let schema = #"{"name":"evolving_tool"}"#
        let id = try await registry.registerTool(
            name: "evolving_tool",
            app: "Test",
            schemaJSON: schema,
            embedding: nil
        )
        
        try await registry.updateToolStatus(id: id, status: "broken", error: "error_1")
        try await registry.updateToolStatus(id: id, status: "active", error: nil)
        try await registry.updateToolStatus(id: id, status: "broken", error: "error_3")
        
        let history = try await registry.getRepairHistory(id: id)
        #expect(history.count == 2, "Only broken updates should append to repair history")
        #expect(history[0].error == "error_1")
        #expect(history[1].error == "error_3")
    }
    
    // MARK: - Repair History
    
    @Test("Getting repair history for tool with history returns entries in order")
    func testGetRepairHistoryEvolution() async throws {
        let registry = try Registry(path: ":memory:")
        let schema1 = #"{"name":"tool","version":1}"#
        let id = try await registry.registerTool(
            name: "tool",
            app: "Test",
            schemaJSON: schema1,
            embedding: nil
        )
        
        // Simulate repair cycle: break → fix → break → fix
        try await registry.updateToolStatus(id: id, status: "broken", error: "missing_field_x")
        try await registry.updateToolStatus(id: id, status: "active", error: nil)
        try await registry.updateToolStatus(id: id, status: "broken", error: "wrong_type_y")
        
        let history = try await registry.getRepairHistory(id: id)
        #expect(history.count == 2)
        #expect(history[0].error == "missing_field_x")
        #expect(history[0].oldSchema == schema1)
        #expect(history[1].error == "wrong_type_y")
        // oldSchema for second entry should reflect the schema after first repair
    }
    
    @Test("Getting repair history for a new tool returns empty array")
    func testRepairHistoryEmpty() async throws {
        let registry = try Registry(path: ":memory:")
        let id = try await registry.registerTool(
            name: "pristine_tool",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        
        let history = try await registry.getRepairHistory(id: id)
        #expect(history.isEmpty)
    }
    
    // MARK: - Consent Gate
    
    @Test("New tools default to requiresApproval = false")
    func testDefaultApprovalGateIsOff() async throws {
        let registry = try Registry(path: ":memory:")
        let id = try await registry.registerTool(
            name: "safe_tool",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        
        let record = try await registry.getTool(id: id)
        #expect(record?.requiresApproval == false)
    }
    
    @Test("Setting approval gate updates the flag")
    func testSetApprovalGate() async throws {
        let registry = try Registry(path: ":memory:")
        let id = try await registry.registerTool(
            name: "dangerous_tool",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        let record = try await registry.getTool(id: id)
        #expect(record?.requiresApproval == true)
    }
    
    @Test("Setting approval gate on non-existent tool throws error")
    func testSetApprovalGateNotFound() async throws {
        let registry = try Registry(path: ":memory:")
        do {
            try await registry.setApprovalGate(id: 99999, requiresApproval: true)
            #expect(Bool(false), "Should have thrown")
        } catch let error as RegistryError {
            #expect(error == .toolNotFound(id: 99999))
        } catch {
            #expect(Bool(false), "Wrong error type: \(error)")
        }
    }
    
    // MARK: - In-Memory Database
    
    @Test("In-memory database works and does not persist to disk")
    func testInMemoryDatabase() async throws {
        let registry = try Registry(path: ":memory:")
        let id = try await registry.registerTool(
            name: "ephemeral",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        
        #expect(id > 0)
        
        // Create a second in-memory registry — should be empty (separate DB)
        let registry2 = try Registry(path: ":memory:")
        let tools = try await registry2.listTools(app: nil)
        #expect(tools.isEmpty)
    }
}
