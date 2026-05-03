import Foundation

// MARK: - Data Models

/// A registered tool in the registry.
struct ToolRecord: Codable, Sendable, Equatable {
    let id: Int64
    let name: String
    let app: String
    let version: Int
    let schemaJSON: String
    let status: String
    let requiresApproval: Bool
    let lastError: String?
    let createdAt: String
    let updatedAt: String
}

/// A single entry in a tool's repair history.
struct RepairEntry: Codable, Sendable, Equatable {
    let timestamp: String
    let oldSchema: String
    let error: String
}

/// A consent gate record — audit trail of approval/rejection.
struct ApprovalRecord: Codable, Sendable, Equatable {
    let timestamp: String
    let action: String
    let outcome: String  // "approved" | "rejected" | "timed_out"
}

// MARK: - Errors

enum RegistryError: Error, Equatable {
    case databaseNotOpen
    case toolNotFound(id: Int64)
    case duplicateTool(app: String, name: String)
    case invalidSchemaJSON
    case migrationFailed(String)
    case queryFailed(String)
}
