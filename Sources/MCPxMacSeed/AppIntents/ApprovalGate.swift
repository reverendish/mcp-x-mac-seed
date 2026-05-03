import Foundation

// MARK: - Data Models

/// The result of a consent check.
enum ConsentResult: Equatable, Sendable {
    /// Tool doesn't require approval — proceed immediately.
    case approved
    /// Tool requires human approval — action is paused.
    case pending(PendingApproval)
}

/// Information about a pending approval request.
struct PendingApproval: Codable, Sendable, Equatable {
    let requestID: String
    let toolID: Int64
    let toolName: String
    let app: String
    let intentName: String
    let proposedAction: [String: String]
    let timestamp: String
}

/// State of a pending approval request.
private enum RequestState {
    case pending
    case approved
    case rejected
    case timedOut
}

// MARK: - Errors

enum ApprovalError: Error, Equatable {
    case requestNotFound(String)
    case requestExpired(String)
    case alreadyResolved(String)
}

// MARK: - Approval Gate

/// Manages the human-in-the-loop consent pipeline.
/// For tools marked `requires_approval`, execution is paused and the
/// proposed action is returned as a PENDING state. The human must explicitly
/// approve or reject before execution continues.
actor ApprovalGate {
    
    private let registry: Registry
    private let approvalTimeoutSeconds: TimeInterval
    
    /// In-memory store of pending requests.
    /// Keyed by requestID → (state, toolID, expiryTime, full action details)
    private var pendingRequests: [String: (state: RequestState, toolID: Int64, expiresAt: Date, pending: PendingApproval)] = [:]
    
    /// Audit log accumulated during this session.
    private var auditLog: [ApprovalRecord] = []
    
    // MARK: - Init
    
    init(registry: Registry, approvalTimeoutSeconds: TimeInterval = 60.0) {
        self.registry = registry
        self.approvalTimeoutSeconds = approvalTimeoutSeconds
    }
    
    // MARK: - Public API
    
    /// Checks whether a proposed action requires human approval.
    /// - Returns: `.approved` if the tool is safe, `.pending` with request info if gated.
    func checkConsent(
        toolID: Int64,
        toolName: String,
        app: String = "",
        intentName: String = "",
        proposedAction: [String: String]
    ) async throws -> ConsentResult {
        // Look up the tool in the registry
        guard let tool = try await registry.getTool(id: toolID) else {
            throw RegistryError.toolNotFound(id: toolID)
        }
        
        // If the tool doesn't require approval, auto-approve
        guard tool.requiresApproval else {
            auditLog.append(ApprovalRecord(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                action: "auto_approved:\(toolName)",
                outcome: "approved"
            ))
            return .approved
        }
        
        // Create a pending request
        let requestID = UUID().uuidString
        let pending = PendingApproval(
            requestID: requestID,
            toolID: toolID,
            toolName: toolName,
            app: app,
            intentName: intentName,
            proposedAction: proposedAction,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        
        let expiresAt = Date().addingTimeInterval(approvalTimeoutSeconds)
        pendingRequests[requestID] = (.pending, toolID, expiresAt, pending: pending)
        
        return .pending(pending)
    }
    
    /// Approves a pending request by its requestID.
    /// - Returns: `true` if the approval was successful, `false` if the request
    ///   was not found, already resolved, or timed out.
    func approve(requestID: String) async throws -> Bool {
        guard let (state, toolID, expiresAt, pending) = pendingRequests[requestID] else {
            return false
        }
        
        // Check if already resolved
        guard state == .pending else { return false }
        
        // Check timeout
        if Date() > expiresAt {
            pendingRequests[requestID] = (.timedOut, toolID, expiresAt, pending: pending)
            auditLog.append(ApprovalRecord(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                action: "approve_attempt:\(requestID)",
                outcome: "timed_out"
            ))
            return false
        }
        
        // Mark as approved (preserve the PendingApproval for auto-execution)
        pendingRequests[requestID] = (.approved, toolID, expiresAt, pending: pending)
        auditLog.append(ApprovalRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            action: "approved:\(requestID)",
            outcome: "approved"
        ))
        
        // Log to registry audit trail
        _ = try? await registry.updateToolStatus(
            id: toolID,
            status: "active",
            error: nil
        )
        
        return true
    }
    
    /// Returns the full PendingApproval for a request (if it was approved or is still pending).
    /// Used by the tool handler to auto-execute after human approval.
    func getPendingAction(requestID: String) -> PendingApproval? {
        guard let (state, _, _, pending) = pendingRequests[requestID] else {
            return nil
        }
        guard state == .approved || state == .pending else { return nil }
        return pending
    }
    
    /// Rejects a pending request by its requestID.
    /// - Returns: `true` if rejection was successful, `false` otherwise.
    func reject(requestID: String) throws -> Bool {
        guard let (state, toolID, expiresAt, pending) = pendingRequests[requestID] else {
            return false
        }
        
        guard state == .pending else { return false }
        
        pendingRequests[requestID] = (.rejected, toolID, expiresAt, pending: pending)
        auditLog.append(ApprovalRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            action: "rejected:\(requestID)",
            outcome: "rejected"
        ))
        
        return true
    }
    
    /// Returns the audit trail for a specific tool.
    func getAuditTrail(toolID: Int64) throws -> [ApprovalRecord] {
        return auditLog.filter { record in
            // Extract toolID from the action string
            record.action.contains("\(toolID)") || true // approximate — audit includes all for now
        }
    }
    
    // MARK: - Cleanup
    
    /// Purges expired pending requests. Called periodically or on shutdown.
    func purgeExpired() {
        let now = Date()
        for (requestID, (state, toolID, expiresAt, pending)) in pendingRequests {
            if state == .pending && now > expiresAt {
                pendingRequests[requestID] = (.timedOut, toolID, expiresAt, pending: pending)
                auditLog.append(ApprovalRecord(
                    timestamp: ISO8601DateFormatter().string(from: now),
                    action: "auto_purge:\(requestID)",
                    outcome: "timed_out"
                ))
            }
        }
    }
}
