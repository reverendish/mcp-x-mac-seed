import Foundation
import GRDB

/// The tool registry — a single actor that owns the SQLite connection.
/// All reads and writes are serialized through the actor to prevent races.
actor Registry {
    
    private let dbQueue: DatabaseQueue
    
    // MARK: - Init
    
    /// Creates a registry backed by an SQLite database at the given path.
    /// Pass ":memory:" for testing (no disk persistence).
    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let queue = try DatabaseQueue(path: path, configuration: config)
        self.dbQueue = queue
        
        // Run migrations synchronously via a write block on the queue itself
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_tools") { db in
            try db.create(table: "tools") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("app", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("schema_json", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("requires_approval", .boolean).notNull().defaults(to: false)
                t.column("last_error", .text)
                t.column("repair_history", .text).notNull().defaults(to: "[]")
                t.column("embedding", .blob)
                t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
                t.column("updated_at", .text).notNull().defaults(sql: "(datetime('now'))")
            }
            
            try db.create(index: "idx_tool_identity", on: "tools", columns: ["app", "name"], unique: true)
            try db.create(index: "idx_tools_status", on: "tools", columns: ["status"])
        }
        try migrator.migrate(queue)
    }
    
    // MARK: - Register Tool
    
    /// Inserts a new tool or upserts if (app, name) already exists.
    /// Returns the tool's ID.
    func registerTool(
        name: String,
        app: String,
        schemaJSON: String,
        embedding: [Float]?
    ) throws -> Int64 {
        try dbQueue.write { db in
            // Check for existing tool with same app+name
            if let existing = try Row.fetchOne(db, sql: """
                SELECT id, version, schema_json FROM tools WHERE app = ? AND name = ?
                """, arguments: [app, name]) {
                
                let id: Int64 = existing["id"]
                let newVersion: Int = existing["version"] + 1
                
                try db.execute(sql: """
                    UPDATE tools
                    SET schema_json = ?,
                        version = ?,
                        status = 'active',
                        last_error = NULL,
                        updated_at = datetime('now')
                    WHERE id = ?
                    """, arguments: [schemaJSON, newVersion, id])
                
                return id
            }
            
            // Fresh insert
            var embeddingData: Data? = nil
            if let emb = embedding {
                embeddingData = emb.withUnsafeBytes { Data($0) }
            }
            
            try db.execute(sql: """
                INSERT INTO tools (name, app, version, schema_json, status, embedding, created_at, updated_at)
                VALUES (?, ?, 1, ?, 'active', ?, datetime('now'), datetime('now'))
                """, arguments: [name, app, schemaJSON, embeddingData])
            
            return db.lastInsertedRowID
        }
    }
    
    // MARK: - List Tools
    
    /// Returns all tools, optionally filtered by app.
    func listTools(app: String?) throws -> [ToolRecord] {
        try dbQueue.read { db in
            if let appFilter = app {
                return try ToolRecord.fetchAll(db, sql: """
                    SELECT * FROM tools WHERE app = ? ORDER BY name
                    """, arguments: [appFilter])
            }
            return try ToolRecord.fetchAll(db, sql: """
                SELECT * FROM tools ORDER BY app, name
                """)
        }
    }
    
    // MARK: - Get Tool
    
    /// Returns a single tool by ID, or nil if not found.
    func getTool(id: Int64) throws -> ToolRecord? {
        try dbQueue.read { db in
            try ToolRecord.fetchOne(db, sql: """
                SELECT * FROM tools WHERE id = ?
                """, arguments: [id])
        }
    }
    
    // MARK: - Update Tool Status
    
    /// Updates a tool's status and optionally logs an error to the repair history.
    /// When status is "broken" and error is provided, appends a RepairEntry to repair_history.
    /// When status is "active" and error is nil, clears last_error (successful repair).
    func updateToolStatus(id: Int64, status: String, error: String?) throws {
        try dbQueue.write { db in
            // Verify tool exists
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, schema_json, repair_history FROM tools WHERE id = ?
                """, arguments: [id]) else {
                throw RegistryError.toolNotFound(id: id)
            }
            
            let currentSchema: String = row["schema_json"]
            let currentHistoryJSON: String = row["repair_history"]
            
            var newRepairHistory: String = currentHistoryJSON
            
            // If status is "broken" and we have an error, append to repair history
            if status == "broken", let errorStr = error {
                var entries = parseRepairHistory(currentHistoryJSON)
                let entry = RepairEntry(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    oldSchema: currentSchema,
                    error: errorStr
                )
                entries.append(entry)
                
                if let data = try? JSONEncoder().encode(entries),
                   let json = String(data: data, encoding: .utf8) {
                    newRepairHistory = json
                }
            }
            
            try db.execute(sql: """
                UPDATE tools
                SET status = ?,
                    last_error = ?,
                    repair_history = ?,
                    updated_at = datetime('now')
                WHERE id = ?
                """, arguments: [status, error, newRepairHistory, id])
        }
    }
    
    // MARK: - Repair History
    
    /// Returns the repair history for a tool as parsed RepairEntry structs.
    func getRepairHistory(id: Int64) throws -> [RepairEntry] {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT repair_history FROM tools WHERE id = ?
                """, arguments: [id]) else {
                throw RegistryError.toolNotFound(id: id)
            }
            
            let json: String = row["repair_history"]
            return parseRepairHistory(json)
        }
    }
    
    // MARK: - Consent Gate
    
    /// Sets or clears the requires_approval flag for a tool.
    func setApprovalGate(id: Int64, requiresApproval: Bool) throws {
        try dbQueue.write { db in
            _ = try db.execute(sql: """
                UPDATE tools SET requires_approval = ?, updated_at = datetime('now') WHERE id = ?
                """, arguments: [requiresApproval, id])
            
            // Check if any row was affected by querying the row after update
            let updated = try Row.fetchOne(db, sql: "SELECT id FROM tools WHERE id = ?", arguments: [id])
            if updated == nil {
                throw RegistryError.toolNotFound(id: id)
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func parseRepairHistory(_ json: String) -> [RepairEntry] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([RepairEntry].self, from: data) else {
            return []
        }
        return entries
    }
}

// MARK: - GRDB Fetchable conformance for ToolRecord

extension ToolRecord: FetchableRecord {
    init(row: Row) {
        id = row["id"]
        name = row["name"]
        app = row["app"]
        version = row["version"]
        schemaJSON = row["schema_json"]
        status = row["status"]
        requiresApproval = row["requires_approval"]
        lastError = row["last_error"]
        createdAt = row["created_at"]
        updatedAt = row["updated_at"]
    }
}
