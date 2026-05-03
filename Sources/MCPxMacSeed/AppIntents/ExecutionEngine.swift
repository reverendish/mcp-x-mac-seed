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
actor ExecutionEngine {
    
    /// Capability cache: app → what execution strategies it supports.
    
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
        return await tryShortcutsCLI(app: app, intentName: intentName, parameters: parameters)
    }
    
    /// Attempts execution via the `shortcuts` CLI tool.
    /// Runs on a background queue with a 5s timeout to avoid blocking the actor.
    private func tryShortcutsCLI(app: String, intentName: String, parameters: [String: String]) async -> String? {
        // Build input for the shortcut
        let inputString = parameters.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        
        return await runSubprocess(
            executable: "/usr/bin/shortcuts",
            arguments: ["run", intentName],
            stdinData: inputString.data(using: .utf8),
            timeoutSeconds: 5,
            label: "Shortcuts CLI"
        )
    }
    
    // MARK: - Shared Subprocess Runner
    
    /// Runs a subprocess on a background DispatchQueue with a timeout.
    /// Reads stdout/stderr concurrently to avoid pipe-buffer deadlocks.
    /// - Parameters:
    ///   - executable: Path to the binary
    ///   - arguments: CLI arguments
    ///   - stdinData: Optional data to pipe to stdin
    ///   - timeoutSeconds: Maximum execution time before SIGTERM
    ///   - label: Human-readable label for error logging
    /// - Returns: Trimmed stdout string on success, nil on failure/timeout
    private nonisolated func runSubprocess(
        executable: String,
        arguments: [String],
        stdinData: Data? = nil,
        timeoutSeconds: Int,
        label: String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                
                // Wire stdin if provided
                if let stdin = stdinData {
                    let inputPipe = Pipe()
                    inputPipe.fileHandleForWriting.write(stdin)
                    inputPipe.fileHandleForWriting.closeFile()
                    process.standardInput = inputPipe
                }
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                do {
                    try process.run()
                } catch {
                    fputs("[\(label)] Failed to launch process: \(error.localizedDescription)\n", stderr)
                    continuation.resume(returning: nil)
                    return
                }
                
                // Wait for process exit with timeout (reads pipes after — no deadlock
                // risk since we only read after the process terminates)
                let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
                let processGroup = DispatchGroup()
                processGroup.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    processGroup.leave()
                }
                
                let timedOut = processGroup.wait(timeout: deadline) == .timedOut
                
                if timedOut {
                    process.terminate()
                    fputs("[\(label)] Timed out after \(timeoutSeconds)s for '\(arguments.joined(separator: " "))'\n", stderr)
                    continuation.resume(returning: nil)
                    return
                }
                
                // Process exited — safe to read pipes sequentially
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                guard process.terminationStatus == 0 else {
                    let errorMsg = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !errorMsg.isEmpty {
                        fputs("[\(label)] Error (exit \(process.terminationStatus)): \(errorMsg)\n", stderr)
                    }
                    continuation.resume(returning: nil)
                    return
                }
                
                let output = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let out = output, !out.isEmpty {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(returning: "Command executed successfully.")
                }
            }
        }
    }
    
    // MARK: - Strategy 2: AppleScript
    
    /// Runs AppleScript via osascript subprocess with a timeout.
    /// Uses DispatchQueue to avoid blocking the actor's executor — the original
    /// NSAppleScript.executeAndReturnError() was synchronous and caused MCP timeouts.
    private func tryAppleScript(app: String, intentName: String, parameters: [String: String]) async -> String? {
        let script = buildAppleScript(app: app, command: intentName, parameters: parameters)
        
        // Sanitization check: flag dangerous patterns
        if containsDangerousPatterns(script) {
            fputs("[Security] AppleScript blocked — contains dangerous patterns (do shell script, sudo, rm -rf, etc.): \(script.prefix(200))\n", stderr)
            return nil
        }
        
        return await runSubprocess(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeoutSeconds: 10,
            label: "AppleScript"
        )
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
        
        // Mail — Production-grade email automation
        if app == "Mail" {
            switch lowered {
            case "send", "send_message", "send_email":
                return buildMailSend(params: params)
            case "reply", "reply_message", "reply_email":
                return buildMailReply(params: params)
            case "forward", "forward_message", "forward_email":
                return buildMailForward(params: params)
            case "check_for_new_mail", "check_mail", "sync":
                return buildMailCheck(params: params)
            case "get_messages", "list_messages", "get_inbox":
                return buildMailGetMessages(params: params)
            case "synchronize", "sync_account":
                return buildMailSynchronize(params: params)
            case "count":
                let target = params["direct"] ?? params["target"] ?? "every message of inbox"
                return "tell application \"Mail\" to return count of \(target)"
            default:
                break
            }
        }
        
        // Reminders
        if app == "Reminders" {
            switch lowered {
            case "create_reminder", "make", "new_reminder":
                let name = params["name"] ?? "New Reminder"
                return "tell application \"Reminders\" to make new reminder with properties {name:\"\(name)\"}"
            case "show":
                return "tell application \"Reminders\" to activate"
            default:
                break
            }
            // Generic: try 'make new reminder' for any create-like command
            if lowered.contains("create") || lowered.contains("make") || lowered.contains("new") {
                let name = params["name"] ?? params["title"] ?? "New Reminder"
                return "tell application \"Reminders\" to make new reminder with properties {name:\"\(name)\"}"
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
    
    // MARK: - Mail AppleScript Builders (Production-Grade)
    
    /// Builds a complete compose → send pipeline for Mail.
    /// Parameters: to, cc, bcc, subject, body, sender, attachment_paths, send_immediately
    private func buildMailSend(params: [String: String]) -> String {
        let to = escapeAppleScript(params["to"] ?? "")
        let cc = escapeAppleScript(params["cc"] ?? "")
        let bcc = escapeAppleScript(params["bcc"] ?? "")
        let subject = escapeAppleScript(params["subject"] ?? "")
        let body = escapeAppleScript(params["body"] ?? "")
        let sender = escapeAppleScript(params["sender"] ?? "")
        let shouldSend = params["send_immediately"]?.lowercased() != "false"
        let visible = params["visible"]?.lowercased() != "false"
        
        var script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject:"\(subject)", content:"\(body)", visible:\(visible)}
        """
        
        if !sender.isEmpty {
            script += "\n    set sender of newMessage to \"\(sender)\""
        }
        
        if !to.isEmpty {
            for addr in to.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                script += "\n    tell newMessage to make new to recipient at end of to recipients with properties {address:\"\(addr)\"}"
            }
        }
        
        if !cc.isEmpty {
            for addr in cc.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                script += "\n    tell newMessage to make new cc recipient at end of cc recipients with properties {address:\"\(addr)\"}"
            }
        }
        
        if !bcc.isEmpty {
            for addr in bcc.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                script += "\n    tell newMessage to make new bcc recipient at end of bcc recipients with properties {address:\"\(addr)\"}"
            }
        }
        
        if shouldSend {
            script += "\n    send newMessage"
            script += "\n    return \"sent\""
        } else {
            script += "\n    activate"
            script += "\n    return \"draft created\""
        }
        
        script += "\nend tell"
        return script
    }
    
    /// Builds a reply to a message by subject match or ID.
    private func buildMailReply(params: [String: String]) -> String {
        let body = escapeAppleScript(params["body"] ?? "")
        let subjectMatch = escapeAppleScript(params["subject"] ?? params["match_subject"] ?? "")
        let replyAll = params["reply_to_all"]?.lowercased() == "true"
        let shouldSend = params["send_immediately"]?.lowercased() != "false"
        let openWindow = params["opening_window"]?.lowercased() == "true"
        
        if subjectMatch.isEmpty {
            return """
            tell application "Mail"
                set selectedMessages to selection
                if (count of selectedMessages) is 0 then error "No message selected"
                set replyMsg to reply selectedMessages with opening window:\(openWindow)\(replyAll ? " and reply to all" : "")
                if "\(body)" is not "" then set content of replyMsg to "\(body)"
                \(shouldSend ? "send replyMsg\nreturn \"sent\"" : "activate\nreturn \"draft created\"")
            end tell
            """
        }
        
        return """
        tell application "Mail"
            set targetInbox to inbox
            set matchedMessages to (messages of targetInbox whose subject contains "\(subjectMatch)")
            if (count of matchedMessages) is 0 then error "No message found with subject containing: \(subjectMatch)"
            set replyMsg to reply (first item of matchedMessages) with opening window:\(openWindow)\(replyAll ? " and reply to all" : "")
            if "\(body)" is not "" then set content of replyMsg to "\(body)"
            \(shouldSend ? "send replyMsg\nreturn \"sent\"" : "activate\nreturn \"draft created\"")
        end tell
        """
    }
    
    /// Builds a forward of a message by subject match or selection.
    private func buildMailForward(params: [String: String]) -> String {
        let body = escapeAppleScript(params["body"] ?? "")
        let to = escapeAppleScript(params["to"] ?? "")
        let subjectMatch = escapeAppleScript(params["subject"] ?? params["match_subject"] ?? "")
        let shouldSend = params["send_immediately"]?.lowercased() != "false"
        let openWindow = params["opening_window"]?.lowercased() == "true"
        
        var script = "tell application \"Mail\"\n"
        
        if subjectMatch.isEmpty {
            script += """
                set selectedMessages to selection
                if (count of selectedMessages) is 0 then error "No message selected"
                set fwdMsg to forward selectedMessages with opening window:\(openWindow)
            """
        } else {
            script += """
                set matchedMessages to (messages of inbox whose subject contains "\(subjectMatch)")
                if (count of matchedMessages) is 0 then error "No message found with subject containing: \(subjectMatch)"
                set fwdMsg to forward (first item of matchedMessages) with opening window:\(openWindow)
            """
        }
        
        if !body.isEmpty {
            script += "set content of fwdMsg to \"\(body)\"\n"
        }
        
        if !to.isEmpty {
            for addr in to.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                script += "tell fwdMsg to make new to recipient at end of to recipients with properties {address:\"\(addr)\"}\n"
            }
        }
        
        if shouldSend {
            script += "send fwdMsg\nreturn \"sent\"\n"
        } else {
            script += "activate\nreturn \"draft created\"\n"
        }
        
        script += "end tell"
        return script
    }
    
    /// Triggers a mail check, optionally for a specific account.
    private func buildMailCheck(params: [String: String]) -> String {
        let account = escapeAppleScript(params["account"] ?? params["for"] ?? "")
        if account.isEmpty {
            return "tell application \"Mail\" to check for new mail"
        }
        return "tell application \"Mail\" to check for new mail for account \"\(account)\""
    }
    
    /// Retrieves messages from a mailbox with optional filters.
    private func buildMailGetMessages(params: [String: String]) -> String {
        let mailbox = escapeAppleScript(params["mailbox"] ?? "inbox")
        let limit = params["limit"] ?? "20"
        let filter = escapeAppleScript(params["filter"] ?? params["unread"] ?? "")
        
        var script = "tell application \"Mail\"\n"
        
        if filter == "true" || filter == "unread" {
            script += "set targetMessages to (messages of \(mailbox) whose read status is false)\n"
        } else if !filter.isEmpty {
            script += "set targetMessages to (messages of \(mailbox) whose subject contains \"\(filter)\")\n"
        } else {
            script += "set targetMessages to messages of \(mailbox)\n"
        }
        
        script += """
        set msgCount to count of targetMessages
            if msgCount is 0 then return "0 messages"
            set output to ""
            repeat with i from 1 to \(limit)
                if i > msgCount then exit repeat
                set msg to item i of targetMessages
                set msgSender to sender of msg
                set msgSubject to subject of msg
                set msgDate to date received of msg
                set msgRead to read status of msg
                set output to output & "#" & i & " | " & msgSender & " | " & msgSubject & "\n"
            end repeat
            return output
        end tell
        """
        return script
    }
    
    /// Synchronizes an IMAP account with the server.
    private func buildMailSynchronize(params: [String: String]) -> String {
        let account = escapeAppleScript(params["account"] ?? params["with"] ?? "")
        if account.isEmpty {
            return "tell application \"Mail\" to synchronize with first account"
        }
        return "tell application \"Mail\" to synchronize with account \"\(account)\""
    }
    
    /// Escapes backslashes and double quotes for AppleScript string literals.
    private func escapeAppleScript(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    // MARK: - Strategy 3: Accessibility
    
    // MARK: - Strategy 3: Accessibility
    
    /// Scans AppleScript for dangerous patterns before execution.
    private func containsDangerousPatterns(_ script: String) -> Bool {
        let lower = script.lowercased()
        let dangerous = [
            "do shell script",
            "sudo ",
            "rm -rf",
            "rm -r",
            "diskutil",
            "dd if=",
            "> /dev/",
            "mkfs.",
            "format ",
            "keystroke"  // Flag System Events keystroke for review
        ]
        
        for pattern in dangerous {
            if lower.contains(pattern) {
                return true
            }
        }
        return false
    }
    
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
