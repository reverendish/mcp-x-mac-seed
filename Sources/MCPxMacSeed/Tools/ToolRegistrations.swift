import Foundation
import MCP

// MARK: - Tool Registry (Dynamic Tool Set)

/// Manages the dynamic set of MCP tools — grows as OpenClaw discovers new intents.
/// The server starts with just the seed tools (scan, register, list, execute).
/// As the agent discovers app capabilities, it registers new tools via register_tool.
actor ToolRegistry {
    /// The full list of currently registered MCP Tool definitions.
    /// Seed tools are always present. Evolved tools are added by OpenClaw at runtime.
    private var tools: [Tool] = []
    
    /// Maps tool name → handler closure. Seed handlers reference core modules.
    /// Evolved handlers are generic (they call execute_intent internally).
    private var handlers: [String: @Sendable (CallTool.Parameters, Server) async throws -> CallTool.Result] = [:]
    
    /// Registers a tool definition and its handler.
    func register(name: String, tool: Tool, handler: @escaping @Sendable (CallTool.Parameters, Server) async throws -> CallTool.Result) {
        tools.append(tool)
        handlers[name] = handler
    }
    
    /// Returns all registered tool definitions (for tools/list).
    func allTools() -> [Tool] {
        return tools
    }
    
    /// Looks up the handler for a tool by name.
    func handler(for name: String) -> (@Sendable (CallTool.Parameters, Server) async throws -> CallTool.Result)? {
        return handlers[name]
    }
}

// MARK: - Helper: Extract string argument

private func arg(_ params: CallTool.Parameters, _ key: String) -> String? {
    guard let args = params.arguments, let value = args[key] else { return nil }
    return value.stringValue
}

private func argBool(_ params: CallTool.Parameters, _ key: String, default: Bool = false) -> Bool {
    guard let args = params.arguments, let value = args[key] else { return `default` }
    return value.boolValue ?? `default`
}

// MARK: - JSON Schema Builders

private func objectSchema(properties: [String: Value], required: [String] = []) -> Value {
    var obj: [String: Value] = [
        "type": .string("object"),
        "properties": .object(properties)
    ]
    if !required.isEmpty {
        obj["required"] = .array(required.map { .string($0) })
    }
    return .object(obj)
}

private func stringProperty(_ description: String) -> Value {
    return .object(["type": .string("string"), "description": .string(description)])
}

private func boolProperty(_ description: String) -> Value {
    return .object(["type": .string("boolean"), "description": .string(description)])
}

private func numberProperty(_ description: String) -> Value {
    return .object(["type": .string("number"), "description": .string(description)])
}

// MARK: - JSON Result Helpers

private func textResult(_ text: String) -> CallTool.Result {
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
}

private func textResultWithData(_ text: String, data: some Codable & Sendable) -> CallTool.Result {
    let structured = try? Value(data)
    return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: structured)
}

private func errorResult(_ message: String) -> CallTool.Result {
    return CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}

// MARK: - Tool Builders

/// Registers all 8 seed tools into the given registry, wiring them to the core modules.
func registerAllTools(
    into registry: ToolRegistry,
    db: Registry,
    intentExplorer: IntentExplorer,
    sdefExtractor: SDEFExtractor,
    accessibilityScanner: AccessibilityScanner,
    screenContext: ScreenContext,
    approvalGate: ApprovalGate
) async {
    
    // ─── Tool 1: scan_for_intents ───
    await registry.register(
        name: "scan_for_intents",
        tool: Tool(
            name: "scan_for_intents",
            title: "Scan App Intents",
            description: "Discovers all AppIntents exposed by a macOS application. Accepts bundle ID ('com.apple.mail') or display name ('Mail'). Returns a JSON array of intent schemas with parameters.",
            inputSchema: objectSchema(
                properties: [
                    "appName": stringProperty("Bundle ID or display name of the application to scan")
                ],
                required: ["appName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
    ) { params, _ in
        guard let appName = arg(params, "appName") else {
            return errorResult("Missing required parameter: appName")
        }
        
        do {
            let intents = try await intentExplorer.scanForIntents(appName: appName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(intents)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
            
            if intents.isEmpty {
                return textResult("No AppIntents discovered for '\(appName)'. The app may not expose intents via Info.plist or AssistantSchemas metadata.")
            }
            
            return textResultWithData(
                "Discovered \(intents.count) intent(s) for \(intents.first?.appName ?? appName).",
                data: ["intents": intents]
            )
        } catch {
            return errorResult("Failed to scan intents for '\(appName)': \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 2: register_tool ───
    await registry.register(
        name: "register_tool",
        tool: Tool(
            name: "register_tool",
            title: "Register Tool",
            description: "Registers a refined tool definition into the persistent SQLite registry. The agent uses this to save discovered and refined tool schemas so they survive server restarts. Supports upsert — re-registering the same app+name updates the schema and increments the version.",
            inputSchema: objectSchema(
                properties: [
                    "name": stringProperty("The tool name (e.g., 'mail_send')"),
                    "app": stringProperty("The app this tool belongs to (e.g., 'Mail')"),
                    "schemaJSON": stringProperty("The full MCP tool schema as a JSON string"),
                    "requiresApproval": boolProperty("Whether this tool requires human approval before execution (default: false)")
                ],
                required: ["name", "app", "schemaJSON"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false)
        )
    ) { params, _ in
        guard let name = arg(params, "name"),
              let app = arg(params, "app"),
              let schemaJSON = arg(params, "schemaJSON") else {
            return errorResult("Missing required parameters: name, app, schemaJSON")
        }
        
        do {
            let id = try await db.registerTool(name: name, app: app, schemaJSON: schemaJSON, embedding: nil)
            
            let requiresApproval = argBool(params, "requiresApproval")
            if requiresApproval {
                try await db.setApprovalGate(id: id, requiresApproval: true)
            }
            
            let record = try await db.getTool(id: id)
            return textResultWithData(
                "Tool '\(name)' registered successfully (id: \(id), version: \(record?.version ?? 1)).",
                data: ["toolID": "\(id)", "version": "\(record?.version ?? 1)"]
            )
        } catch {
            return errorResult("Failed to register tool: \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 3: list_registered_tools ───
    await registry.register(
        name: "list_registered_tools",
        tool: Tool(
            name: "list_registered_tools",
            title: "List Registered Tools",
            description: "Lists all tools currently registered in the SQLite registry. Can optionally filter by app name or perform semantic search. Returns tool metadata including name, app, status, version, and whether approval is required.",
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty("Optional app name to filter by (e.g., 'Mail')"),
                    "search": stringProperty("Optional natural language query for semantic search (e.g., 'send a message', 'find files')"),
                    "limit": numberProperty("Maximum results (default: 10, for semantic search)")
                ],
                required: []
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
    ) { params, _ in
        do {
            let searchQuery = arg(params, "search")
            let limit = Int(arg(params, "limit") ?? "10") ?? 10
            
            // Semantic search path
            if let query = searchQuery, !query.isEmpty {
                let results = try await db.searchTools(query: query, limit: limit)
                
                if results.isEmpty {
                    return textResult("No semantically matching tools found for: '\(query)'. Try a different search term or use app filter instead.")
                }
                
                let summary = results.map { r in
                    "- \(r.tool.name) [\(r.tool.app)] v\(r.tool.version) \(r.tool.status == "active" ? "✅" : "⚠️") score: \(String(format: "%.3f", r.score))"
                }.joined(separator: "\n")
                
                let encoder = JSONEncoder()
                let json = try encoder.encode(results)
                let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
                
                return textResultWithData(
                    "Semantic search for '\(query)': \(results.count) result(s).\n\(summary)",
                    data: ["results": jsonStr]
                )
            }
            
            // Exact app filter path
            let tools = try await db.listTools(app: arg(params, "app"))
            
            if tools.isEmpty {
                return textResult("No tools registered yet. Use scan_for_intents to discover app capabilities, then register_tool to save them.")
            }
            
            let summary = tools.map { t in
                "- \(t.name) [\(t.app)] v\(t.version) \(t.status == "active" ? "✅" : "⚠️")\(t.requiresApproval ? " 🔒" : "")"
            }.joined(separator: "\n")
            
            let encoder = JSONEncoder()
            let json = try encoder.encode(tools)
            let jsonStr = String(data: json, encoding: .utf8) ?? "[]"
            
            return textResultWithData(
                "\(tools.count) tool(s) registered:\n\(summary)",
                data: ["tools": tools]
            )
        } catch {
            return errorResult("Failed to list tools: \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 4: execute_intent ───
    let engine = ExecutionEngine()
    await registry.register(
        name: "execute_intent",
        tool: Tool(
            name: "execute_intent",
            title: "Execute Intent",
            description: "Executes an AppIntent or AppleScript action. Uses the triple-threat execution engine: tries AppIntents first, falls back to AppleScript (if SDEF available), then Accessibility UI automation. Respects the consent gate — if the tool requires approval, returns a PENDING state.",
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty("The app to execute against (e.g., 'Mail')"),
                    "intentName": stringProperty("The intent or command name to execute"),
                    "parametersJSON": stringProperty("JSON string of parameters to pass to the intent"),
                    "mode": stringProperty("Execution mode: 'appintent', 'applescript', or 'auto' (default)")
                ],
                required: ["app", "intentName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        )
    ) { params, _ in
        guard let app = arg(params, "app"),
              let intentName = arg(params, "intentName") else {
            return errorResult("Missing required parameters: app, intentName")
        }
        
        let mode = arg(params, "mode") ?? "auto"
        let paramsJSON = arg(params, "parametersJSON") ?? "{}"
        
        // Parse parameters from JSON
        let parameters: [String: String]
        if let data = paramsJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parameters = dict.mapValues { "\($0)" }
        } else {
            parameters = [:]
        }
        
        // Check consent gate via trust classification
        let trustTier = TrustClassifier.classify(toolName: intentName)
        let allTools = try? await db.listTools(app: app)
        
        // Tools are registered as {app}_{command} (e.g., "mail_check_for_new_mail").
        // Try bare intent name first, then the prefixed form.
        var matchingTool = allTools?.first { $0.name == intentName }
        if matchingTool == nil {
            let appPrefix = app.lowercased().replacingOccurrences(of: " ", with: "_")
            matchingTool = allTools?.first { $0.name == "\(appPrefix)_\(intentName)" }
        }
        
        // Only gate Tier 2 (sensitive) actions, and only when the tool is registered.
        // Unregistered tools can't be gated — they execute with the default trust tier
        // and the ExecutionEngine's own dangerous-pattern filter.
        let requiresGate = (matchingTool?.requiresApproval == true || trustTier == .sensitive)
            && matchingTool != nil
        
        if requiresGate, let tool = matchingTool {
            let consentResult = try await approvalGate.checkConsent(
                toolID: tool.id,
                toolName: intentName,
                app: app,
                intentName: intentName,
                proposedAction: parameters
            )
            
            if case .pending(let info) = consentResult {
                return textResultWithData(
                    "⏸️ Tool '\(intentName)' requires human approval before execution.\n\nRequest ID: \(info.requestID)\nApp: \(app)\nParameters: \(parameters)\n\nCall request_human_approval with action='approve' and this requestID to proceed.",
                    data: ["status": "pending", "requestID": info.requestID]
                )
            }
        }
        
        // Execute via triple-threat engine
        // Check if the tool has a stored AppleScript from Repairman correction
        var prebuiltScript: String? = nil
        if let tool = matchingTool,
           let schemaData = tool.schemaJSON.data(using: .utf8),
           let schemaDict = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
           let storedScript = schemaDict["appleScript"] as? String {
            prebuiltScript = storedScript
        }
        
        let result = await engine.execute(app: app, intentName: intentName, parameters: parameters, mode: mode, prebuiltScript: prebuiltScript)
        
        let encoder = JSONEncoder()
        let resultJSON = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        if result.success {
            return textResultWithData(
                "✅ Executed '\(intentName)' on '\(app)' via \(result.strategy.rawValue) (\(Int(result.durationMs))ms).\nOutput: \(result.output ?? "(no output)")",
                data: ["result": resultJSON]
            )
        } else {
            return textResultWithData(
                "❌ Failed to execute '\(intentName)' on '\(app)' via \(result.strategy.rawValue).\nError: \(result.error ?? "unknown")\n\nThis failure has been captured. Use the Repairman workflow to fix the schema: analyze the failure, check the app's SDEF (fetch_scripting_dictionary), and re-register the tool with corrections.",
                data: ["result": resultJSON],
            )
        }
    }
    
    // ─── Tool 5: fetch_scripting_dictionary ───
    await registry.register(
        name: "fetch_scripting_dictionary",
        tool: Tool(
            name: "fetch_scripting_dictionary",
            title: "Fetch Scripting Dictionary",
            description: "Extracts the AppleScript scripting dictionary (SDEF) from a macOS application. Returns all commands, classes, properties, and elements as structured JSON. The agent MUST reference this dictionary before writing any AppleScript for the app — this is the source of truth, eliminating hallucinated commands.",
            inputSchema: objectSchema(
                properties: [
                    "appName": stringProperty("Bundle ID or display name of the app whose SDEF to fetch (e.g., 'Finder', 'com.apple.mail')")
                ],
                required: ["appName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
    ) { params, _ in
        guard let appName = arg(params, "appName") else {
            return errorResult("Missing required parameter: appName")
        }
        
        do {
            let dict = try await sdefExtractor.fetchScriptingDictionary(appName: appName)
            
            if dict.commands.isEmpty && dict.classes.isEmpty {
                return textResult("'\(dict.appName)' has no AppleScript scripting dictionary (no SDEF found). This app may not support AppleScript automation.\n\nUse scan_for_intents to check for AppIntents, or get_ui_tree for Accessibility fallback.")
            }
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let json = try encoder.encode(dict)
            let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
            
            return textResultWithData(
                "Scripting dictionary for '\(dict.appName)': \(dict.commands.count) commands, \(dict.classes.count) classes across \(dict.suites.count) suite(s).\n\n⚠️ IMPORTANT: The agent MUST reference the exact command signatures from this dictionary when constructing AppleScript. Any command not present in this SDEF will fail at runtime.",
                data: ["dictionary": dict]
            )
        } catch SDEFError.appNotFound {
            return errorResult("App '\(appName)' not found on this system.")
        } catch {
            return errorResult("Failed to fetch scripting dictionary: \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 6: get_ui_tree ───
    await registry.register(
        name: "get_ui_tree",
        tool: Tool(
            name: "get_ui_tree",
            title: "Get UI Tree",
            description: "Scans the accessibility UI element tree of a running macOS application. Returns all UI elements with their roles, titles, positions, and enabled states. This is the brute-force fallback for apps that have no AppIntents or AppleScript support (Electron apps, Java apps, legacy apps).",
            inputSchema: objectSchema(
                properties: [
                    "appName": stringProperty("Bundle ID or display name of the app to scan (e.g., 'Finder', 'Discord')"),
                    "maxDepth": numberProperty("Maximum depth to traverse the UI tree (default: 10)")
                ],
                required: ["appName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
    ) { params, _ in
        guard let appName = arg(params, "appName") else {
            return errorResult("Missing required parameter: appName")
        }
        
        let maxDepth = Int(arg(params, "maxDepth") ?? "10") ?? 10
        
        do {
            let tree = try await accessibilityScanner.getUITree(appName: appName, maxDepth: maxDepth)
            
            guard let root = tree.rootElement else {
                return textResult("No UI elements found for '\(tree.appName)'. The app may not be running.")
            }
            
            func countElements(_ el: UIAccessibilityElement) -> Int {
                return 1 + el.children.reduce(0) { $0 + countElements($1) }
            }
            let totalElements = countElements(root)
            
            let roles = Set(tree.elements(matching: "").map { $0.role })  // gets all roles
            let buttons = tree.elements(matching: "AXButton").count
            let textFields = tree.elements(matching: "AXTextField").count
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let json = try encoder.encode(tree)
            let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
            
            return textResultWithData(
                "UI tree for '\(tree.appName)': \(totalElements) total elements (depth limited to \(maxDepth)).\nDetected: \(buttons) button(s), \(textFields) text field(s).\n\nUse this tree to construct precise Accessibility API interactions when AppIntents and AppleScript are unavailable.",
                data: ["tree": tree]
            )
        } catch {
            return errorResult("Failed to scan UI tree: \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 7: request_human_approval ───
    await registry.register(
        name: "request_human_approval",
        tool: Tool(
            name: "request_human_approval",
            title: "Request Human Approval",
            description: "Checks or requests human approval for a pending action. When a tool is marked requires_approval, execution pauses and this tool must be called to resolve. Use 'check' to see if approval is needed, 'approve' to authorize, or 'reject' to deny.",
            inputSchema: objectSchema(
                properties: [
                    "toolID": stringProperty("The tool ID to check approval for"),
                    "toolName": stringProperty("The name of the tool being checked"),
                    "action": stringProperty("The action: 'check', 'approve', or 'reject'"),
                    "requestID": stringProperty("The request ID from a prior PENDING response (required for approve/reject)"),
                    "proposedActionJSON": stringProperty("JSON describing the proposed action (required for check)")
                ],
                required: ["toolID", "toolName", "action"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false)
        )
    ) { params, _ in
        guard let toolIDStr = arg(params, "toolID"),
              let toolName = arg(params, "toolName"),
              let action = arg(params, "action") else {
            return errorResult("Missing required parameters: toolID, toolName, action")
        }
        
        guard let id = Int64(toolIDStr) else {
            return errorResult("toolID must be a valid integer")
        }
        
        do {
            switch action {
            case "check":
                let proposed = arg(params, "proposedActionJSON") ?? "{}"
                guard let data = proposed.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    return errorResult("proposedActionJSON must be a valid JSON object with string values")
                }
                
                let result = try await approvalGate.checkConsent(toolID: id, toolName: toolName, proposedAction: dict)
                
                switch result {
                case .approved:
                    return textResultWithData(
                        "✅ Tool '\(toolName)' does not require human approval. Auto-approved.",
                        data: ["status": "approved"]
                    )
                case .pending(let info):
                    return textResultWithData(
                        "⏸️ Tool '\(toolName)' REQUIRES HUMAN APPROVAL.\n\nRequest ID: \(info.requestID)\nProposed action: \(info.proposedAction)\n\nCall request_human_approval again with action='approve' or action='reject' and this requestID to proceed.",
                        data: ["status": "pending", "requestID": info.requestID]
                    )
                }
                
            case "approve":
                guard let requestID = arg(params, "requestID") else {
                    return errorResult("requestID is required for approve action")
                }
                let approved = try await approvalGate.approve(requestID: requestID)
                guard approved else {
                    return textResult("❌ Approval failed. The request may have expired, already been resolved, or the requestID is invalid.")
                }
                
                // Auto-execute: retrieve the approved action and run it
                guard let pendingAction = await approvalGate.getPendingAction(requestID: requestID) else {
                    return textResult("✅ Action approved, but could not retrieve action details for execution.")
                }
                
                let engine = ExecutionEngine()
                let result = await engine.execute(
                    app: pendingAction.app,
                    intentName: pendingAction.intentName,
                    parameters: pendingAction.proposedAction,
                    mode: "auto"
                )
                
                if result.success {
                    let encoder = JSONEncoder()
                    let resultJSON = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return textResult(
                        "✅ Approved and executed '\(pendingAction.intentName)' on '\(pendingAction.app)' via \(result.strategy.rawValue) (\(Int(result.durationMs))ms).\nOutput: \(result.output ?? "(no output)")\n\nResult: \(resultJSON)"
                    )
                } else {
                    return textResult(
                        "⚠️ Approved but execution failed for '\(pendingAction.intentName)' on '\(pendingAction.app)'.\nError: \(result.error ?? "unknown")\n\nThis failure has been captured. Use the Repairman workflow to fix the schema."
                    )
                }
                
            case "reject":
                guard let requestID = arg(params, "requestID") else {
                    return errorResult("requestID is required for reject action")
                }
                let rejected = try await approvalGate.reject(requestID: requestID)
                return textResult(rejected
                    ? "❌ Action rejected. The pending request has been denied."
                    : "Rejection failed. The request may have expired or already been resolved.")
                
            default:
                return errorResult("Unknown action '\(action)'. Use: check, approve, or reject.")
            }
        } catch {
            return errorResult("Approval operation failed: \(error.localizedDescription)")
        }
    }
    
    // ─── Tool 8: capture_screen_context ───
    await registry.register(
        name: "capture_screen_context",
        tool: Tool(
            name: "capture_screen_context",
            title: "Capture Screen Context",
            description: "Captures the current screen context — what the user is looking at right now. Returns the active application, focused window (title, bounds, position), and display configuration. This gives the agent 'eyes' to understand 'send this' or 'fill out this form' commands.",
            inputSchema: objectSchema(
                properties: [
                    "includeOCR": boolProperty("Whether to include OCR text from the active window (default: false)")
                ],
                required: []
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        )
    ) { params, _ in
        let includeOCR = argBool(params, "includeOCR")
        
        do {
            let info = try await screenContext.captureScreenContext(includeOCR: includeOCR)
            
            var summary = ""
            summary += "Active app: \(info.activeApplication.name)"
            if let bid = info.activeApplication.bundleIdentifier {
                summary += " (\(bid))"
            }
            
            if let window = info.activeWindow {
                summary += "\nActive window: \(window.title ?? "Untitled")"
                summary += "\n  Owner: \(window.ownerName)"
                summary += "\n  Bounds: \(Int(window.x)), \(Int(window.y)) \(Int(window.width))×\(Int(window.height))"
            } else {
                summary += "\nNo active window detected."
            }
            
            summary += "\nDisplays: \(info.displays.count)"
            for d in info.displays {
                summary += "\n  Display \(d.id): \(Int(d.width))×\(Int(d.height))\(d.isMain ? " (main)" : "")"
            }
            
            return textResultWithData(
                "Screen context captured at \(info.timestamp):\n\(summary)",
                data: info
            )
        } catch {
            return errorResult("Failed to capture screen context: \(error.localizedDescription)")
        }
    }
}
