import Foundation

// MARK: - Repair Context

/// Structured context for the Repairman: what went wrong and what to do about it.
struct RepairContext: Codable, Sendable {
    /// The tool that failed.
    let toolName: String
    let appName: String
    let toolVersion: Int
    
    /// The error that occurred.
    let errorCode: String?
    let errorMessage: String
    let failedAt: String
    
    /// The schema that was in use when the failure occurred.
    let currentSchema: String?
    
    /// Previous repair history (for context on what's been tried).
    let repairHistory: [RepairEntry]
    
    /// Available SDEF dictionary (for AppleScript-based tools, if relevant).
    let scriptingDictionary: ScriptingDictionary?
    
    /// The parameters that were attempted.
    let attemptedParameters: [String: String]?
}

// MARK: - Repair Result

/// Errors the Repairman can encounter.
enum RepairError: Error, Equatable {
    case circuitBreakerTripped(tool: String, attempts: Int, lastError: String)
    
    var localizedDescription: String {
        switch self {
        case .circuitBreakerTripped(let tool, let attempts, let lastError):
            return "Circuit breaker tripped for '\(tool)' after \(attempts) failed repair attempts. Last error: \(lastError). Manual review required."
        }
    }
}

/// The result of a repair attempt: a proposed schema update.
struct RepairProposal: Codable, Sendable {
    let toolName: String
    let appName: String
    let proposedSchema: String
    let repairStrategy: RepairStrategy
    let reasoning: String
    
    enum RepairStrategy: String, Codable, Sendable {
        case addMissingParameter       // Parameter missing → add it as optional
        case fixParameterType          // Wrong type → correct it
        case addRequiredField          // Missing required field → add it
        case updateDescription         // Schema mismatch → update from SDEF
        case fallbackToAppleScript     // AppIntent failed → use SDEF-based script
        case fallbackToAccessibility   // Both failed → use AX fallback
        case manualReview              // Human needs to intervene
    }
}

// MARK: - Repairman Service

/// The Repairman analyzes tool failures and proposes schema corrections.
/// Implements a circuit breaker: max 3 repair attempts per tool before giving up.
actor Repairman {
    
    private let registry: Registry
    private let sdefExtractor: SDEFExtractor
    private let intentExplorer: IntentExplorer
    
    /// Maximum repair attempts before circuit breaker trips.
    private let maxRepairAttempts = 3
    
    init(registry: Registry, sdefExtractor: SDEFExtractor, intentExplorer: IntentExplorer) {
        self.registry = registry
        self.sdefExtractor = sdefExtractor
        self.intentExplorer = intentExplorer
    }
    
    // MARK: - Public API
    
    /// Analyzes a tool failure and produces a structured repair context.
    /// This is the data packet the agent needs to diagnose and fix the problem.
    func analyzeFailure(
        toolName: String,
        appName: String,
        error: String,
        attemptedParams: [String: String]? = nil
    ) async throws -> RepairContext {
        // Get the current tool state from registry
        let tools = try await registry.listTools(app: appName)
        let tool = tools.first { $0.name == toolName }
        
        // Get repair history
        let history: [RepairEntry]
        if let id = tool?.id {
            history = (try? await registry.getRepairHistory(id: id)) ?? []
        } else {
            history = []
        }
        
        // Circuit breaker: if too many repair attempts, signal manual review
        if history.count >= maxRepairAttempts {
            throw RepairError.circuitBreakerTripped(
                tool: toolName,
                attempts: history.count,
                lastError: history.last?.error ?? "unknown"
            )
        }
        
        // Try to fetch the SDEF for this app (relevant for AppleScript failures)
        let sdef = try? await sdefExtractor.fetchScriptingDictionary(appName: appName)
        
        // Log the error to registry
        if let id = tool?.id {
            try? await registry.updateToolStatus(id: id, status: "broken", error: error)
        }
        
        return RepairContext(
            toolName: toolName,
            appName: appName,
            toolVersion: tool?.version ?? 0,
            errorCode: extractErrorCode(error),
            errorMessage: error,
            failedAt: ISO8601DateFormatter().string(from: Date()),
            currentSchema: tool?.schemaJSON,
            repairHistory: history,
            scriptingDictionary: sdef,
            attemptedParameters: attemptedParams
        )
    }
    
    /// Captures a repair — stores the success/failure in the registry.
    func recordRepair(
        toolName: String,
        appName: String,
        newSchema: String,
        success: Bool
    ) async throws {
        // Re-register with the new schema (version auto-increments)
        let id = try await registry.registerTool(
            name: toolName,
            app: appName,
            schemaJSON: newSchema,
            embedding: nil
        )
        
        // Update status: active if successful, keep broken if not
        try await registry.updateToolStatus(
            id: id,
            status: success ? "active" : "broken",
            error: success ? nil : "Repair attempt failed — manual review needed"
        )
    }
    
    /// Returns the full evolution history of a tool (for debugging).
    func getEvolutionHistory(toolName: String, appName: String) async throws -> [RepairEntry] {
        let tools = try await registry.listTools(app: appName)
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            return []
        }
        return (try? await registry.getRepairHistory(id: tool.id)) ?? []
    }
    
    // MARK: - Helpers
    
    private func extractErrorCode(_ error: String) -> String? {
        let lowercased = error.lowercased()
        
        // Check for "required" first (more specific) before "missing"
        if lowercased.contains("missing") && lowercased.contains("required") {
            return "MISSING_REQUIRED"
        }
        if lowercased.contains("missing") && lowercased.contains("parameter") {
            return "MISSING_PARAMETER"
        }
        if lowercased.contains("missing") {
            return "MISSING_PARAMETER"
        }
        if lowercased.contains("type") && (lowercased.contains("mismatch") || lowercased.contains("expected")) {
            return "TYPE_MISMATCH"
        }
        if lowercased.contains("validation") || lowercased.contains("invalid") {
            return "VALIDATION_ERROR"
        }
        if lowercased.contains("permission") || lowercased.contains("denied") {
            return "PERMISSION_DENIED"
        }
        if lowercased.contains("not found") || lowercased.contains("doesn't exist") {
            return "NOT_FOUND"
        }
        return "UNKNOWN"
    }
}

// MARK: - Repairman Prompt Template

/// The prompt template that teaches OpenClaw how to act as the Repairman.
/// This is injected into the agent's context when a tool failure is detected.
struct RepairmanPrompt {
    
    /// Generates the full system prompt for the Repairman role.
    static func generate(from context: RepairContext) -> String {
        var prompt = ""
        prompt += "# Repairman: Fix the Broken Tool\n\n"
        prompt += "A tool has failed. Your job is to analyze the failure and propose a corrected schema.\n\n"
        
        prompt += "## Failure Details\n"
        prompt += "- **Tool:** `\(context.toolName)`\n"
        prompt += "- **App:** `\(context.appName)`\n"
        prompt += "- **Version:** v\(context.toolVersion)\n"
        prompt += "- **Error Code:** \(context.errorCode ?? "unknown")\n"
        prompt += "- **Error Message:** \(context.errorMessage)\n"
        prompt += "- **Failed At:** \(context.failedAt)\n\n"
        
        if let params = context.attemptedParameters, !params.isEmpty {
            prompt += "### Attempted Parameters\n"
            for (key, value) in params {
                prompt += "- `\(key)`: `\(value)`\n"
            }
            prompt += "\n"
        }
        
        if let schema = context.currentSchema {
            prompt += "### Current Schema (the broken one)\n```json\n\(schema)\n```\n\n"
        }
        
        if !context.repairHistory.isEmpty {
            prompt += "### Repair History (what's been tried)\n"
            for (i, entry) in context.repairHistory.enumerated() {
                prompt += "**Attempt \(i + 1):** \(entry.timestamp)\n"
                prompt += "- Error: \(entry.error)\n"
                prompt += "- Schema at time:\n```json\n\(entry.oldSchema)\n```\n\n"
            }
        }
        
        if let sdef = context.scriptingDictionary, !sdef.commands.isEmpty {
            prompt += "### App Scripting Dictionary (Source of Truth)\n"
            prompt += "This app has \(sdef.commands.count) scripting commands. Reference these exact signatures when constructing fixes:\n\n"
            
            // Show relevant commands (ones matching the tool name)
            let relevant = sdef.commands.filter { cmd in
                cmd.name.localizedCaseInsensitiveContains(context.toolName) ||
                context.toolName.localizedCaseInsensitiveContains(cmd.name)
            }
            
            for cmd in (relevant.isEmpty ? Array(sdef.commands.prefix(5)) : relevant) {
                prompt += "- **\(cmd.name)**\(cmd.description.map { ": \($0)" } ?? "")\n"
                for param in cmd.parameters {
                    let optional = param.isOptional ? " (optional)" : " (required)"
                    prompt += "  - `\(param.name)`: \(param.type)\(optional)\(param.description.map { " — \($0)" } ?? "")\n"
                }
            }
            
            if !relevant.isEmpty && relevant.count < sdef.commands.count {
                prompt += "\n\(sdef.commands.count - relevant.count) additional commands available. Use `fetch_scripting_dictionary` to see them all.\n"
            }
            prompt += "\n⚠️ **CRITICAL:** Only propose fixes using commands and parameters that exist in this SDEF. Any parameter or command not listed here will fail at runtime.\n\n"
        }
        
        prompt += "## Your Task\n"
        prompt += "1. **Diagnose** the root cause — what specifically went wrong?\n"
        prompt += "2. **Propose** a corrected MCP tool schema (JSON) that fixes the issue\n"
        prompt += "3. **Explain** your reasoning — what did you change and why?\n"
        prompt += "4. If the error suggests the AppIntent approach won't work, consider suggesting a fallback strategy (AppleScript SDK, Accessibility API)\n\n"
        
        prompt += "After you've designed the fix, use `register_tool` to save it with the corrected schema.\n"
        prompt += "The registry will auto-increment the version number and clear the error state on successful registration.\n"
        
        return prompt
    }
}
