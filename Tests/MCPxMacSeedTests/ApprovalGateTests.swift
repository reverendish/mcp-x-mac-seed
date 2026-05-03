import Testing
import Foundation
@testable import MCPxMacSeed

struct ApprovalGateTests {
    
    // MARK: - Pending State
    
    @Test("Consent check returns PENDING when tool requires approval")
    func testConsentCheckPending() async throws {
        let registry = try Registry(path: ":memory:")
        
        // Register a tool with requires_approval
        let id = try await registry.registerTool(
            name: "delete_email",
            app: "Mail",
            schemaJSON: #"{"action":"delete"}"#,
            embedding: nil
        )
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        let gate = ApprovalGate(registry: registry)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "delete_email",
            proposedAction: ["emailID": "12345", "action": "delete"]
        )
        
        guard case .pending(let pendingInfo) = result else {
            #expect(Bool(false), "Should return PENDING state")
            return
        }
        
        #expect(pendingInfo.toolID == id)
        #expect(pendingInfo.toolName == "delete_email")
        #expect(pendingInfo.app == "")
        #expect(pendingInfo.intentName == "")
        #expect(!pendingInfo.requestID.isEmpty, "Should have a unique request ID")
        #expect(!pendingInfo.timestamp.isEmpty)
    }
    
    @Test("Consent check returns APPROVED when tool doesn't require approval")
    func testConsentCheckAutoApproved() async throws {
        let registry = try Registry(path: ":memory:")
        
        // Register a safe tool (requires_approval defaults to false)
        let id = try await registry.registerTool(
            name: "read_email",
            app: "Mail",
            schemaJSON: #"{"action":"read"}"#,
            embedding: nil
        )
        
        let gate = ApprovalGate(registry: registry)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "read_email",
            proposedAction: ["emailID": "67890"]
        )
        
        guard case .approved = result else {
            #expect(Bool(false), "Safe tool should auto-approve")
            return
        }
    }
    
    @Test("Consent check throws error for non-existent tool")
    func testConsentCheckNonExistentTool() async throws {
        let registry = try Registry(path: ":memory:")
        let gate = ApprovalGate(registry: registry)
        
        do {
            _ = try await gate.checkConsent(
                toolID: 99999,
                toolName: "fake_tool",
                proposedAction: [:]
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as RegistryError {
            #expect(error == .toolNotFound(id: 99999))
        }
    }
    
    // MARK: - Approval Flow
    
    @Test("Approving a pending request transitions to APPROVED")
    func testApproveRequest() async throws {
        let registry = try Registry(path: ":memory:")
        
        let id = try await registry.registerTool(
            name: "send_payment",
            app: "Banking",
            schemaJSON: #"{"action":"send"}"#,
            embedding: nil
        )
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        let gate = ApprovalGate(registry: registry)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "send_payment",
            proposedAction: ["amount": "100", "recipient": "Alice"]
        )
        
        guard case .pending(let pendingInfo) = result else {
            #expect(Bool(false), "Should be PENDING")
            return
        }
        
        // Now approve
        let approved = try await gate.approve(requestID: pendingInfo.requestID)
        #expect(approved, "Approval should succeed")
        
        // Second approval of same request should fail (already consumed)
        let doubleApprove = try await gate.approve(requestID: pendingInfo.requestID)
        #expect(!doubleApprove, "Double-approval should fail")
    }
    
    @Test("Rejecting a pending request transitions to REJECTED")
    func testRejectRequest() async throws {
        let registry = try Registry(path: ":memory:")
        
        let id = try await registry.registerTool(
            name: "format_drive",
            app: "DiskUtility",
            schemaJSON: #"{"action":"format"}"#,
            embedding: nil
        )
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        let gate = ApprovalGate(registry: registry)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "format_drive",
            proposedAction: ["volume": "Macintosh HD"]
        )
        
        guard case .pending(let pendingInfo) = result else {
            #expect(Bool(false), "Should be PENDING")
            return
        }
        
        let rejected = try await gate.reject(requestID: pendingInfo.requestID)
        #expect(rejected, "Rejection should succeed")
    }
    
    @Test("Approving/rejecting unknown request returns false")
    func testUnknownRequestID() async throws {
        let registry = try Registry(path: ":memory:")
        let gate = ApprovalGate(registry: registry)
        
        let approved = try await gate.approve(requestID: "nonexistent-request-id")
        #expect(!approved)
        
        let rejected = try await gate.reject(requestID: "nonexistent-request-id")
        #expect(!rejected)
    }
    
    // MARK: - Timeout
    
    @Test("Pending request times out after specified duration")
    func testTimeout() async throws {
        let registry = try Registry(path: ":memory:")
        
        let id = try await registry.registerTool(
            name: "timed_action",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        // Create gate with very short timeout (0.1 seconds)
        let gate = ApprovalGate(registry: registry, approvalTimeoutSeconds: 0.1)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "timed_action",
            proposedAction: ["test": "true"]
        )
        
        guard case .pending(let pendingInfo) = result else {
            #expect(Bool(false), "Should be PENDING")
            return
        }
        
        // Wait for timeout
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        
        // Try to approve after timeout — should fail
        let approved = try await gate.approve(requestID: pendingInfo.requestID)
        #expect(!approved, "Approval after timeout should fail")
    }
    
    // MARK: - Audit Trail
    
    @Test("Approval outcomes are logged as audit records")
    func testAuditTrail() async throws {
        let registry = try Registry(path: ":memory:")
        
        let id = try await registry.registerTool(
            name: "audited_tool",
            app: "Test",
            schemaJSON: "{}",
            embedding: nil
        )
        try await registry.setApprovalGate(id: id, requiresApproval: true)
        
        let gate = ApprovalGate(registry: registry)
        let result = try await gate.checkConsent(
            toolID: id,
            toolName: "audited_tool",
            proposedAction: ["test": "true"]
        )
        
        guard case .pending(let info) = result else { return }
        
        // Approve
        _ = try await gate.approve(requestID: info.requestID)
        
        // Check audit trail
        let auditLog = try await gate.getAuditTrail(toolID: id)
        #expect(!auditLog.isEmpty, "Should have audit records")
        #expect(auditLog.count == 1)
        #expect(auditLog[0].outcome == "approved")
    }
}
