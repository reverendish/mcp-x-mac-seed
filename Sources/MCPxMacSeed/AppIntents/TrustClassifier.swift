import Foundation

// MARK: - Trust Tiers

/// Tiered trust model for tool execution.
/// Tier 1 (safe) auto-executes. Tier 2 (sensitive) requires HITL approval.
enum TrustTier: String, Codable, Sendable {
    case safe       // Auto-execute: read-only queries, navigation, get info
    case sensitive  // HITL required: deletes, sends, modifies, shell access
}

/// Classifies an action into a trust tier based on its name and parameters.
struct TrustClassifier {
    
    /// Patterns that indicate a safe (Tier 1) action.
    private static let safePatterns: [String] = [
        "get", "read", "list", "check", "count", "exists",
        "open", "activate", "reveal", "select",
        "close", "quit", "hide",
        "copy", "duplicate",
        "capture", "fetch", "scan", "search",
        "view", "show", "display", "lookup",
        "properties", "info", "status", "bounds",
        "frontmost", "active", "focused",
        "print",
    ]
    
    /// Patterns that indicate a sensitive (Tier 2) action.
    private static let sensitivePatterns: [String] = [
        "delete", "remove", "erase", "trash", "empty",
        "send", "submit", "post", "publish", "share",
        "create", "make", "new", "add", "insert",
        "modify", "change", "update", "edit", "set",
        "move", "rename", "replace",
        "install", "uninstall", "download", "upload",
        "format", "erase", "wipe", "destroy",
        "execute", "run", "sudo", "shell",
        "payment", "transfer", "purchase", "buy",
        "sign", "authorize", "authenticate",
    ]
    
    /// Classifies a tool name into a trust tier.
    static func classify(toolName: String) -> TrustTier {
        let lower = toolName.lowercased()
        
        // Check sensitive first (more specific patterns win)
        for pattern in sensitivePatterns {
            if lower.contains(pattern) {
                return .sensitive
            }
        }
        
        // Check safe
        for pattern in safePatterns {
            if lower.contains(pattern) {
                return .safe
            }
        }
        
        // Unknown → sensitive by default (fail safe)
        return .sensitive
    }
    
    /// Returns whether a given AppleScript contains patterns that should be
    /// flagged to the user before execution.
    static func flaggedPatterns(in script: String) -> [String] {
        let lower = script.lowercased()
        var flags: [String] = []
        
        let checks: [(String, String)] = [
            ("do shell script", "Runs a shell command"),
            ("sudo ", "Runs with admin privileges"),
            ("rm -", "Deletes files"),
            ("diskutil", "Modifies disks/volumes"),
            ("keystroke", "Simulates keyboard input — could type anything"),
            ("with administrator privileges", "Requests admin access"),
            ("/dev/", "Accesses raw devices"),
            ("system events", "Uses System Events for UI automation"),
            ("tell application \"terminal\"", "Opens Terminal"),
            ("tell application \"iterm\"", "Opens iTerm"),
        ]
        
        for (pattern, description) in checks {
            if lower.contains(pattern) {
                flags.append("⚠️ \(description): '\(pattern)'")
            }
        }
        
        return flags
    }
}
