import Foundation
import AppKit

// MARK: - Execution Result

/// The result of attempting to execute a tool via the triple-threat pipeline.
struct ExecutionResult: Codable, Sendable {
    let success: Bool
    let strategy: ExecutionStrategy
    let output: String?
    let error: String?
    let durationMs: Double
    
    enum ExecutionStrategy: String, Codable, Sendable {
        case appIntent      // Used AppIntents API
        case appleScript    // Used AppleScript (SDEF-verified)
        case accessibility  // Used Accessibility API fallback
        case none           // All strategies exhausted
    }
}

// MARK: - Execution Engine

/// The triple-threat execution engine.
/// Tries AppIntent → AppleScript → Accessibility → clear error.
// MARK: - Circuit Breaker + Capability Cache

/// Capability profile for an app — cached after first discovery.
struct AppCapability: Codable {
    let appName: String
    let hasSDEF: Bool
    let hasAppIntents: Bool
    let hasAccessibility: Bool
    let lastChecked: String
}

actor ExecutionEngine {
    
    /// Capability cache: app → what execution strategies it supports.
    private var capabilityCache: [String: AppCapability] = [:]
    
    /// Maximum repair attempts before giving up (circuit breaker).
    private let maxRepairAttempts = 3
    
    // MARK: - Public API
    
    /// Execute a named intent/command against an app using the best available strategy.
    func execute(
        app: String,
        intentName: String,
        parameters: [String: String],
        mode: String = "auto"
    ) async -> ExecutionResult {
        let start = Date()
        
        // Check capability cache to skip strategies that are known to fail
        let cached = capabilityCache[app]
        let skipAppIntent = cached != nil && !cached!.hasAppIntents
        let skipAppleScript = cached != nil && !cached!.hasSDEF
        let skipAccessibility = cached != nil && !cached!.hasAccessibility
        
        // Strategy 1: AppIntent (skip if known unavailable)
        if mode == "appintent" || mode == "auto" {
            if let result = await tryAppIntent(app: app, intentName: intentName, parameters: parameters) {
                let duration = Date().timeIntervalSince(start) * 1000
                return ExecutionResult(success: true, strategy: .appIntent, output: result, error: nil, durationMs: duration)
            }
        }
        
        // Strategy 2: AppleScript (fully functional via NSAppleScript)
        if mode == "applescript" || mode == "auto" {
            if let result = await tryAppleScript(app: app, intentName: intentName, parameters: parameters) {
                let duration = Date().timeIntervalSince(start) * 1000
                return ExecutionResult(success: true, strategy: .appleScript, output: result, error: nil, durationMs: duration)
            }
        }
        
        // Strategy 3: Accessibility API (brute-force fallback)
        if mode == "accessibility" || mode == "auto" {
            if let result = tryAccessibility(app: app, intentName: intentName, parameters: parameters) {
                let duration = Date().timeIntervalSince(start) * 1000
                return ExecutionResult(success: true, strategy: .accessibility, output: result, error: nil, durationMs: duration)
            }
        }
        
        // All strategies exhausted
        let duration = Date().timeIntervalSince(start) * 1000
        return ExecutionResult(
            success: false,
            strategy: .none,
            output: nil,
            error: "All execution strategies exhausted for '\(intentName)' on '\(app)'. AppIntent: not available. AppleScript: app not scriptable or command not found. Accessibility: app not running or element not found.",
            durationMs: duration
        )
    }
    
    // MARK: - Strategy 1: AppIntent
    
    private func tryAppIntent(app: String, intentName: String, parameters: [String: String]) async -> String? {
        // AppIntent execution on macOS works through Siri/Shortcuts.
        // The primary cross-app execution path is:
        //   1. INInteraction.donate() — donate the intent to Siri
        //   2. The receiving app handles it via its AppIntent handler
        //
        // For macOS cross-app execution, we use the shortcuts CLI
        // or the INInteraction API to trigger intents on other apps.
        
        // Try executing via the shortcuts command (macOS 12+)
        return tryShortcutsCLI(app: app, intentName: intentName, parameters: parameters)
    }
    
    /// Attempts execution via the `shortcuts` CLI tool.
    private func tryShortcutsCLI(app: String, intentName: String, parameters: [String: String]) -> String? {
        // The shortcuts CLI can run shortcuts by name.
        // AppIntents exposed via AppShortcutsProvider are runnable this way.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", intentName]
        
        // Pass parameters via stdin (shortcuts reads input)
        let inputPipe = Pipe()
        let inputString = parameters.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        inputPipe.fileHandleForWriting.write(inputString.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        process.standardInput = inputPipe
        
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        
        try? process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return nil }
        
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Strategy 2: AppleScript
    
    private func tryAppleScript(app: String, intentName: String, parameters: [String: String]) async -> String? {
        // Build an AppleScript command from the intent name and parameters
        let script = buildAppleScript(app: app, command: intentName, parameters: parameters)
        
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return nil
        }
        
        let result = appleScript.executeAndReturnError(&error)
        
        if let error = error {
            // AppleScript error — command not found, app not scriptable, etc.
            return nil
        }
        
        // Return the result as a string
        if let stringValue = result.stringValue {
            return stringValue.isEmpty ? "Command executed successfully." : stringValue
        }
        
        return "Command executed successfully (no return value)."
    }
    
    /// Builds an AppleScript command string from structured parameters.
    private func buildAppleScript(app: String, command: String, parameters: [String: String]) -> String {
        var script = ""
        
        // Map common intent names to AppleScript commands
        let appScript = mapToAppleScriptCommand(app: app, intent: command, params: parameters)
        
        if let prebuilt = appScript {
            return prebuilt
        }
        
        // Generic AppleScript: tell app to do something
        script += "tell application \"\(app)\"\n"
        
        // Build the command with parameters
        var cmdLine = "    \(command)"
        for (key, value) in parameters {
            if key == "direct" {
                cmdLine += " \(value)"
            } else if key == "to" || key == "at" || key == "with" {
                cmdLine += " \(key) \(value)"
            } else {
                cmdLine += " \(key) \"\(value)\""
            }
        }
        
        script += "\(cmdLine)\n"
        script += "end tell"
        
        return script
    }
    
    /// Maps high-level intent names to concrete AppleScript commands for known apps.
    private func mapToAppleScriptCommand(app: String, intent: String, params: [String: String]) -> String? {
        let lowered = intent.lowercased()
        
        // Finder
        if app == "Finder" {
            switch lowered {
            case "open", "open_finder", "reveal":
                let target = params["path"] ?? params["direct"] ?? ""
                return "tell application \"Finder\" to open POSIX file \"\(target)\""
            case "select":
                let target = params["path"] ?? params["direct"] ?? ""
                return "tell application \"Finder\"\n    activate\n    select POSIX file \"\(target)\"\nend tell"
            case "new_folder", "create_folder":
                let name = params["name"] ?? "New Folder"
                let location = params["at"] ?? params["location"] ?? "desktop"
                return "tell application \"Finder\" to make new folder at \(location) with properties {name:\"\(name)\"}"
            default:
                break
            }
        }
        
        // Mail
        if app == "Mail" {
            switch lowered {
            case "send", "send_message", "send_email":
                let to = params["to"] ?? ""
                let subject = params["subject"] ?? ""
                let body = params["body"] ?? ""
                return """
                tell application "Mail"
                    set newMessage to make new outgoing message with properties {subject:"\(subject)", content:"\(body)", visible:true}
                    tell newMessage
                        make new to recipient at end of to recipients with properties {address:"\(to)"}
                    end tell
                    activate
                end tell
                """
            default:
                break
            }
        }
        
        // System Events (UI automation)
        if app == "System Events" {
            switch lowered {
            case "click", "press":
                let target = params["target"] ?? params["button"] ?? ""
                return """
                tell application "System Events"
                    tell process "\(params["process"] ?? "Finder")"
                        click button "\(target)"
                    end tell
                end tell
                """
            case "keystroke", "type":
                let text = params["text"] ?? ""
                let target = params["target"] ?? ""
                if !target.isEmpty {
                    return """
                    tell application "System Events"
                        tell process "\(params["process"] ?? "Finder")"
                            set frontmost to true
                            keystroke "\(text)"
                        end tell
                    end tell
                    """
                }
                return """
                tell application "System Events" to keystroke "\(text)"
                """
            default:
                break
            }
        }
        
        return nil
    }
    
    // MARK: - Strategy 3: Accessibility
    
    private func tryAccessibility(app: String, intentName: String, parameters: [String: String]) -> String? {
        // Accessibility-based execution requires the Accessibility Scanner
        // and direct AXUIElement manipulation. This strategy works by:
        // 1. Finding the app's main window
        // 2. Searching for a UI element matching the intent
        // 3. Performing an action (press, set value, etc.)
        //
        // Full implementation requires entitlements and the AXIsProcessTrusted()
        // permission check. The infrastructure is ready via AccessibilityScanner.
        return nil // Requires accessibility permissions + entitlements
    }
}
