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

// MARK: - SDEF Command Lookup Table

/// A lightweight lookup table for SDEF commands, avoiding the need for full
/// SDEFExtractor instantiation inside ExecutionEngine.
struct SdefCommandInfo: Codable, Sendable {
    let commandName: String        // Exact SDEF command name (e.g., "next track")
    let parameters: [String]       // Parameter names in order
    let description: String
}

/// Result of fuzzy-matching an intent name against SDEF commands.
struct SdefCommandMatch {
    let sdefName: String           // The matched SDEF command name
    let confidence: Double         // 0.0–1.0 match confidence
}

// MARK: - Execution Engine

/// The triple-threat execution engine.
/// Tries AppleScript (SDEF-aware, primary) → AppIntent (Shortcuts, fallback) → Accessibility (last resort).
/// Note: AppIntents on macOS require apps to donate intents to Shortcuts first —
/// coverage is sparse. AppleScript via SDEF is the most reliable path for scriptable apps.
actor ExecutionEngine {
    
    /// Capability cache: app → what execution strategies it supports.
    
    /// Maximum repair attempts before giving up (circuit breaker).
    private let maxRepairAttempts = 3
    
    /// SDEF command cache: app → [command info]. Populated on first use.
    private var sdefCache: [String: [SdefCommandInfo]] = [:]
    
    // MARK: - Public API
    
    /// Execute a named intent/command against an app using the best available strategy.
    /// If prebuiltScript is provided (from tool schema), it's used with parameter substitution.
    func execute(
        app: String,
        intentName: String,
        parameters: [String: String],
        mode: String = "auto",
        prebuiltScript: String? = nil
    ) async -> ExecutionResult {
        let start = Date()
        
        // Check capability cache to skip strategies that are known to fail
        
        // Strategy 1: AppleScript (most reliable for macOS — 20+ years of scripting support)
        if mode == "applescript" || mode == "auto" {
            if let result = await tryAppleScript(app: app, intentName: intentName, parameters: parameters, prebuiltScript: prebuiltScript) {
                let duration = Date().timeIntervalSince(start) * 1000
                return ExecutionResult(success: true, strategy: .appleScript, output: result, error: nil, durationMs: duration)
            }
        }
        
        // Strategy 2: AppIntent (Shortcuts CLI — requires apps to have donated intents)
        if mode == "appintent" || mode == "auto" {
            if let result = await tryAppIntent(app: app, intentName: intentName, parameters: parameters) {
                let duration = Date().timeIntervalSince(start) * 1000
                return ExecutionResult(success: true, strategy: .appIntent, output: result, error: nil, durationMs: duration)
            }
        }
        
        // Strategy 3: Accessibility API (brute-force UI automation fallback)
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
            error: "All execution strategies exhausted for '\(intentName)' on '\(app)'. AppleScript: app not scriptable or command not found. AppIntent: not available. Accessibility: app not running or element not found.",
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
    /// Auto-launches the target app if it's not running before executing the script.
    /// If prebuiltScript is provided (from a repaired tool schema), it's used directly
    /// with parameter substitution.
    private func tryAppleScript(app: String, intentName: String, parameters: [String: String], prebuiltScript: String? = nil) async -> String? {
        // Use the stored prebuilt script if available (from Repairman-corrected tool schema)
        let script: String
        let positionalArgs: [String]
        if let prebuilt = prebuiltScript {
            (script, positionalArgs) = buildPositionalScript(prebuilt, params: parameters)
        } else {
            script = buildAppleScript(app: app, command: intentName, parameters: parameters)
            positionalArgs = []
        }
        
        // Sanitization check: flag dangerous patterns BEFORE app launch and subprocess
        if containsDangerousPatterns(script) {
            fputs("[Security] AppleScript blocked — contains dangerous patterns (do shell script, sudo, rm -rf, etc.): \(script.prefix(200))\n", stderr)
            return nil
        }
        
        // Auto-launch the app if it's not running (fixes "Application isn't running. (-600)" errors)
        await ensureAppIsRunning(app: app)
        
        // Build osascript args: -e script -- arg1 arg2 ...
        var osascriptArgs = ["-e", script]
        if !positionalArgs.isEmpty {
            osascriptArgs.append("--")
            osascriptArgs.append(contentsOf: positionalArgs)
        }
        
        return await runSubprocess(
            executable: "/usr/bin/osascript",
            arguments: osascriptArgs,
            timeoutSeconds: 10,
            label: "AppleScript"
        )
    }
    
    /// Wraps a prebuilt AppleScript in 'on run argv' and extracts positional args.
    /// Security: dynamic values are passed as argv[n], never string-interpolated.
    /// This prevents AppleScript injection (CWE-74/94) through parameter values.
    private func buildPositionalScript(_ prebuilt: String, params: [String: String]) -> (String, [String]) {
        // The prebuilt script uses {key} placeholders. Convert to argv[n] references.
        var script = prebuilt
        var positionalArgs: [String] = []
        
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            if value.isEmpty { continue }
            let sanitized = sanitizeForAppleScript(value)
            positionalArgs.append(sanitized)
            let argIdx = positionalArgs.count
            script = script.replacingOccurrences(of: "{\(key)}", with: "(item \(argIdx) of argv)")
        }
        
        let wrapped = "on run argv\n" + script + "\nend run"
        return (wrapped, positionalArgs)
    }
    
    /// Whitelist-based sanitizer for values passed to AppleScript.
    /// Strips characters that could enable injection through string boundaries.
    private func sanitizeForAppleScript(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" +
            "0123456789 _-.,:;!?@#$%&()+=[]{}|/~`^<>" +
            "\n\t\r"
        )
        let filtered = String(value.unicodeScalars.filter { allowed.contains($0) })
        return String(filtered.prefix(1024)).trimmingCharacters(in: .whitespaces)
    }
    
    /// Substitutes {paramName} placeholders in a prebuilt AppleScript with actual values.
    private func substituteParameters(in script: String, params: [String: String]) -> String {
        var result = script
        for (key, value) in params {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
    
    /// Launches an app via `open -a` if it's not already running.
    /// This prevents "Application isn't running. (-600)" errors from AppleScript.
    /// Uses `open -a` which is idempotent — if the app is already running, it just brings
    /// it to the foreground, so we can always call it safely.
    private func ensureAppIsRunning(app: String) async {
        // Always launch — `open -a` is safe and idempotent
        // If the app is already running, it just activates it
        _ = await runSubprocess(
            executable: "/usr/bin/open",
            arguments: ["-a", app],
            timeoutSeconds: 5,
            label: "Auto-Launch \(app)"
        )
        // Wait for the app to initialize — some apps need a moment before they accept AppleScript
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
    }
    
    /// Builds an AppleScript command string from structured parameters.
    /// First tries hardcoded mappings, then SDEF-aware generation, then generic fallback.
    private func buildAppleScript(app: String, command: String, parameters: [String: String]) -> String {
        var script = ""
        
        // Tier 1: Hardcoded mappings for known apps (fastest, most reliable)
        let appScript = mapToAppleScriptCommand(app: app, intent: command, params: parameters)
        
        if let prebuilt = appScript {
            fputs("[AS-Build] Tier 1 (hardcoded) hit for '\(app)'::'\(command)'\n", stderr)
            return prebuilt
        }
        
        // Tier 2: SDEF-aware command lookup (auto-adapts to new apps)
        // Only use SDEF matches with high confidence (>0.9) — exact/space-normalized only
        // Lower confidence matches are too risky and fall through to Tier 3
        if let sdefMatch = findSdefCommand(app: app, intent: command), sdefMatch.confidence >= 0.9 {
            fputs("[AS-Build] Tier 2 (SDEF) hit for '\(app)'::'\(command)' → '\(sdefMatch.sdefName)' (conf=\(sdefMatch.confidence))\n", stderr)
            return buildSdefBasedAppleScript(
                app: app,
                sdefCommand: sdefMatch.sdefName,
                parameters: parameters
            )
        }
        
        // Tier 3: Generic fallback (tell app "X" to Y with parameter injection)
        // Normalize command name: underscores → spaces, close → quit heuristic
        fputs("[AS-Build] Tier 3 (generic) for '\(app)'::'\(command)'\n", stderr)
        let normalized = normalizeCommandName(command, app: app)
        
        script += "tell application \"\(app)\"\n"
        
        // Build the command with parameters
        var cmdLine = "    \(normalized)"
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
    
    // MARK: - SDEF-Aware Command Resolution
    
    /// Fuzzy-matches an intent/command name against the app's SDEF commands.
    /// Uses multiple strategies: exact match → underscore-to-space → prefix/substring.
    private func findSdefCommand(app: String, intent: String) -> SdefCommandMatch? {
        // Try to load SDEF from cache or extract on-demand
        let sdefCommands = loadSdefCommands(for: app)
        guard let commands = sdefCommands, !commands.isEmpty else {
            fputs("[SDEF-Match] No SDEF commands for '\(app)' — returning nil\n", stderr)
            return nil
        }
        
        fputs("[SDEF-Match] Searching \(commands.count) commands for '\(intent)'\n", stderr)
        
        let lowered = intent.lowercased()
        
        // Strategy 1: Exact match (already normalized by caller)
        // Special case: "close" → prefer "quit" over "close" for app-level close
        for cmd in commands {
            if cmd.commandName.lowercased() == lowered {
                // If the intent is "close" but the app has "quit", prefer "quit"
                // since the evolved tools use "close" to mean "close the app"
                if lowered == "close" {
                    if let quitCommand = commands.first(where: { $0.commandName.lowercased() == "quit" }) {
                        return SdefCommandMatch(sdefName: quitCommand.commandName, confidence: 1.0)
                    }
                }
                return SdefCommandMatch(sdefName: cmd.commandName, confidence: 1.0)
            }
        }
        
        // Strategy 2: Underscore-to-space normalization
        let spaceNormalized = lowered.replacingOccurrences(of: "_", with: " ")
        for cmd in commands {
            if cmd.commandName.lowercased() == spaceNormalized {
                return SdefCommandMatch(sdefName: cmd.commandName, confidence: 0.95)
            }
        }
        
        // Strategy 3: Prefix match (e.g., "reload" matches "reload calendars")
        for cmd in commands {
            let cmdLower = cmd.commandName.lowercased()
            if cmdLower.hasPrefix(spaceNormalized) || spaceNormalized.hasPrefix(cmdLower) {
                return SdefCommandMatch(sdefName: cmd.commandName, confidence: 0.7)
            }
        }
        
        // Strategy 4: Substring match (e.g., "track" matches "next track")
        var bestMatch: SdefCommandMatch?
        for cmd in commands {
            let cmdLower = cmd.commandName.lowercased()
            if cmdLower.contains(spaceNormalized) && spaceNormalized.count > 2 {
                let score = Double(spaceNormalized.count) / Double(cmdLower.count)
                if score > (bestMatch?.confidence ?? 0.3) {
                    bestMatch = SdefCommandMatch(sdefName: cmd.commandName, confidence: score * 0.5)
                }
            }
        }
        
        return bestMatch
    }
    
    /// Loads SDEF commands for an app, with caching.
    /// Uses a synchronous subprocess to avoid async/Sendable issues in the buildAppleScript chain.
    private func loadSdefCommands(for app: String) -> [SdefCommandInfo]? {
        // Check cache first
        if let cached = sdefCache[app] {
            fputs("[SDEF-Cache] Hit for '\(app)': \(cached.count) commands\n", stderr)
            return cached.isEmpty ? nil : cached
        }
        
        // Cache miss — extract synchronously
        fputs("[SDEF-Cache] Miss for '\(app)' — extracting...\n", stderr)
        let extracted = extractSdefCommands(app: app)
        fputs("[SDEF-Cache] Extracted \(extracted.count) commands for '\(app)'\n", stderr)
        sdefCache[app] = extracted
        return extracted.isEmpty ? nil : extracted
    }
    
    /// Extracts SDEF commands for a given app by calling `/usr/bin/sdef` directly.
    /// Runs NSWorkspace lookup on MainActor to avoid thread-safety issues.
    private nonisolated func extractSdefCommands(app: String) -> [SdefCommandInfo] {
        // Resolve app path — use MainActor for NSWorkspace
        guard let resolvedPath = findAppPathSync(app) else { return [] }
        
        // Run /usr/bin/sdef synchronously
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [resolvedPath]
        
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        
        do {
            try process.run()
        } catch {
            return []
        }
        
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else { return [] }
        
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let xmlString = String(data: stdoutData, encoding: .utf8) else { return [] }
        
        return parseSdefCommands(from: xmlString)
    }
    
    /// Resolves an app to its path on the filesystem, blocking the current thread.
    /// Used by extractSdefCommands which is nonisolated and synchronous.
    private nonisolated func findAppPathSync(_ identifier: String) -> String? {
        // First try common paths (no NSWorkspace needed)
        let commonPaths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "/System/Library/CoreServices/\(identifier).app",
            "/Applications/Utilities/\(identifier).app",
        ]
        for path in commonPaths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return nil
    }
    
    /// Parses command names from raw SDEF XML using regex.
    private nonisolated func parseSdefCommands(from xml: String) -> [SdefCommandInfo] {
        var commands: [SdefCommandInfo] = []
        
        // Pattern: <command name="NAME" ...>
        guard let regex = try? NSRegularExpression(
            pattern: #"<command\s+name="([^"]*)"(?:\s+hidden="(yes)")?(?:[^>]*)\s*(?:description="([^"]*)")?"#,
            options: []
        ) else { return [] }
        
        let range = NSRange(xml.startIndex..., in: xml)
        let matches = regex.matches(in: xml, options: [], range: range)
        
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: xml) else { continue }
            let rawName = String(xml[nameRange])
            if let hiddenRange = Range(match.range(at: 2), in: xml) {
                if xml[hiddenRange] == "yes" { continue }
            }
            var desc = ""
            if let descRange = Range(match.range(at: 3), in: xml) {
                desc = String(xml[descRange])
            }
            if rawName.isEmpty { continue }
            commands.append(SdefCommandInfo(
                commandName: rawName,
                parameters: [],
                description: desc
            ))
        }
        
        return commands
    }
    
    /// Builds AppleScript using SDEF-verified command names.
    private func buildSdefBasedAppleScript(app: String, sdefCommand: String, parameters: [String: String]) -> String {
        var script = "tell application \"\(app)\"\n"
        
        // Use the exact SDEF command name (e.g., "next track" not "next_track")
        var cmdLine = "    \(sdefCommand)"
        
        for (key, value) in parameters {
            if key == "direct" {
                cmdLine += " \(value)"
            } else if key == "to" || key == "at" || key == "with" || key == "of" || key == "in" || key == "for" {
                cmdLine += " \(key) \(value)"
            } else {
                cmdLine += " \(key):\"\(value)\""
            }
        }
        
        script += "\(cmdLine)\n"
        script += "end tell"
        
        return script
    }
    
    /// Normalizes LLM-generated command names to AppleScript-friendly format.
    /// Applies known heuristics: close→quit, underscore→space, etc.
    private func normalizeCommandName(_ command: String, app: String) -> String {
        var normalized = command
        
        // Heuristic: "close" for standalone apps means "quit"
        // "close" for documents/windows uses the app's own window closing
        if normalized.lowercased() == "close" {
            // Apps that support window closing
            let windowApps = ["Finder", "Preview", "TextEdit", "Pages", "Numbers", "Keynote"]
            if windowApps.contains(app) {
                return "close window 1"
            }
            return "quit"
        }
        
        // Heuristic: replace underscores with spaces for multi-word commands
        if normalized.contains("_") {
            normalized = normalized.replacingOccurrences(of: "_", with: " ")
        }
        
        return normalized
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
            case "activate":
                return "tell application \"Finder\" to activate"
            case "select":
                let target = params["path"] ?? params["direct"] ?? ""
                return "tell application \"Finder\"\n    activate\n    select POSIX file \"\(target)\"\nend tell"
            case "count":
                let target = params["direct"] ?? params["target"] ?? "every item of desktop"
                return "tell application \"Finder\" to return count of \(target)"
            case "new_folder", "create_folder", "make":
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
        
        // Calendar
        if app == "Calendar" {
            switch lowered {
            case "create calendar", "make":
                let name = params["name"] ?? "New Calendar"
                return "tell application \"Calendar\" to make new calendar with properties {name:\"\(name)\"}"
            case "show", "activate":
                return "tell application \"Calendar\" to activate"
            case "reload calendars":
                return "tell application \"Calendar\" to reload calendars"
            case "switch view":
                let view = params["view"] ?? params["direct"] ?? "month"
                return "tell application \"Calendar\" to switch view to \(view) view"
            default:
                break
            }
        }
        
        // Safari
        if app == "Safari" {
            switch lowered {
            case "activate", "show":
                return "tell application \"Safari\" to activate"
            case "search the web", "search", "open location":
                let query = params["direct"] ?? params["query"] ?? ""
                let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                if escaped.hasPrefix("http") {
                    return "tell application \"Safari\" to open location \"\(escaped)\""
                }
                return "tell application \"Safari\" to search the web for \"\(escaped)\""
            case "do javascript", "execute javascript":
                let script = params["direct"] ?? params["script"] ?? ""
                return "tell application \"Safari\" to do JavaScript \"\(script)\" in document 1"
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
        guard AXIsProcessTrusted() else {
            return nil
        }
        
        // Find the app's process via NSWorkspace
        let runningApps = NSWorkspace.shared.runningApplications
        guard let targetApp = runningApps.first(where: {
            $0.localizedName == app || $0.bundleIdentifier == app || $0.bundleIdentifier == "com.apple.\(app)"
        }) else {
            return nil // App not running — AppleScript already tried auto-launch
        }
        
        let pid = targetApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get the focused window, falling back to main window
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        if windowResult != .success || focusedWindow == nil {
            var mainWindow: CFTypeRef?
            let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindow)
            guard mainResult == .success, let mainWin = mainWindow else {
                return nil
            }
            focusedWindow = mainWin
        }
        
        // Safety: cast to AXUIElement
        guard let axWindow = focusedWindow as! AXUIElement? else { return nil }
        
        let lowered = intentName.lowercased()
        
        // Strategy: find a button/menu item matching the intent name and press it
        if let result = findAndPressElement(axWindow, matching: lowered, intentName: intentName) {
            return result
        }
        
        // Fallback: set value for text fields
        if let value = parameters["value"] ?? parameters["direct"] {
            if let result = findAndSetValue(axWindow, value: value) {
                return result
            }
        }
        
        return nil
    }
    
    /// Recursively search AX elements for a match and press it.
    private func findAndPressElement(_ element: AXUIElement, matching query: String, intentName: String) -> String? {
        // Get element's attributes
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        var desc: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        
        let titleStr = (title as? String ?? "").lowercased()
        let descStr = (desc as? String ?? "").lowercased()
        let roleStr = (role as? String ?? "").lowercased()
        
        // Check if this element matches and is actionable
        let actionableRoles = ["axbutton", "axmenuitem", "axlink", "axcheckbox", "axradiobutton"]
        if actionableRoles.contains(roleStr) && (titleStr.contains(query) || descStr.contains(query)) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success {
                return "Pressed '\(titleStr)' (\(roleStr)) in \(intentName)"
            }
        }
        
        // Recurse into children
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let childArray = children as? [AXUIElement] {
            for child in childArray {
                if let result = findAndPressElement(child, matching: query, intentName: intentName) {
                    return result
                }
            }
        }
        
        return nil
    }
    
    /// Find a text field and set its value.
    private func findAndSetValue(_ element: AXUIElement, value: String) -> String? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = (role as? String ?? "")
        
        if roleStr == "AXTextField" || roleStr == "AXTextArea" {
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
            return "Set value of \(roleStr)"
        }
        
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let childArray = children as? [AXUIElement] {
            for child in childArray {
                if let result = findAndSetValue(child, value: value) {
                    return result
                }
            }
        }
        
        return nil
    }
}
