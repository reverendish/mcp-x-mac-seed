import Foundation
import AppKit

actor SystemBootstrap {
    
    private let registry: Registry
    private let sdefExtractor: SDEFExtractor
    private let intentExplorer: IntentExplorer
    private let markerPath: String
    
    init(registry: Registry, sdefExtractor: SDEFExtractor, intentExplorer: IntentExplorer) {
        self.registry = registry
        self.sdefExtractor = sdefExtractor
        self.intentExplorer = intentExplorer
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.markerPath = appSupport.appendingPathComponent("MCPxMacSeed/.bootstrap_complete").path
    }
    
    func bootstrapIfNeeded() async -> Int {
        guard !FileManager.default.fileExists(atPath: markerPath) else { return 0 }
        
        fputs("[Bootstrap] First run — scanning all apps for capabilities...\n", stderr)
        var registered = 0
        
        registered += await bootstrapAllApps()
        registered += await bootstrapShortcuts()
        
        let date = ISO8601DateFormatter().string(from: Date())
        try? date.write(toFile: markerPath, atomically: true, encoding: .utf8)
        fputs("[Bootstrap] Done. \(registered) tools auto-discovered.\n", stderr)
        return registered
    }
    
    // MARK: - Scan All Apps
    
    private func bootstrapAllApps() async -> Int {
        var count = 0
        var seen = Set<String>()
        
        let dirs = [
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications",
            "/Applications",
            "/Applications/Utilities",
            "/System/iOSSupport/Applications",
            "/Library/Application Support/Apple",
        ]
        
        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            
            for item in contents where item.hasSuffix(".app") && !item.hasPrefix(".") {
                let name = String(item.dropLast(4))
                let lower = name.lowercased()
                guard !seen.contains(lower) else { continue }
                seen.insert(lower)
                
                let path = "\(dir)/\(item)"
                
                // Skip known problematic apps
                let skipApps = ["automator application stub", "automator runner"]
                if skipApps.contains(lower) { continue }
                
                // Skip known apps that cause `sdef` to hang
                // Some CoreServices system daemon agents trigger an infinite loop in sdef.
                let knownHangers = ["keyboardaccessagent", "accessibility reader"]
                if knownHangers.contains(lower) { continue }
                
                // Strategy 1: SDEF (AppleScript — most reliable)
                let dict = try? await sdefExtractor.fetchScriptingDictionary(appName: path)
                if let sdef = dict, !sdef.commands.isEmpty {
                    // Consolidate all commands into ONE tool per app
                    let visibleCommands = sdef.commands.filter { !$0.isHidden }
                    let toolName = sanitize(name)
                    let schema = buildConsolidatedSDEFSchema(app: name, commands: visibleCommands)
                    let id = try? await registry.registerTool(name: toolName, app: name, schemaJSON: schema, embedding: nil)
                    if let toolID = id, TrustClassifier.classify(toolName: toolName) == .sensitive {
                        try? await registry.setApprovalGate(id: toolID, requiresApproval: true)
                    }
                    count += 1
                    continue
                }
                
                // Strategy 2: AppIntents from Info.plist
                let intents = try? await intentExplorer.scanForIntents(appName: name)
                if let discovered = intents, !discovered.isEmpty {
                    for intent in discovered.prefix(10) {
                        let toolName = sanitize("\(name)_\(intent.intentName)")
                        let schema = buildIntentSchema(intent: intent)
                        let id = try? await registry.registerTool(name: toolName, app: name, schemaJSON: schema, embedding: nil)
                        if let toolID = id, TrustClassifier.classify(toolName: toolName) == .sensitive {
                            try? await registry.setApprovalGate(id: toolID, requiresApproval: true)
                        }
                        count += 1
                    }
                }
            }
        }
        
        return count
    }
    
    // MARK: - Shortcuts
    
    private func bootstrapShortcuts() async -> Int {
        var count = 0
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        proc.arguments = ["list"]
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
        
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return 0 }
        
        for name in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            let toolName = sanitize("shortcut_\(name)")
            let schema = #"{"name":"\#(toolName)","description":"Run '\#(name)' shortcut","app":"Shortcuts","inputSchema":{"type":"object","properties":{},"required":[]}}"#
            _ = try? await registry.registerTool(name: toolName, app: "Shortcuts", schemaJSON: schema, embedding: nil)
            count += 1
        }
        return count
    }
    
    // MARK: - Schema Builders
    
    private func buildConsolidatedSDEFSchema(app: String, commands: [ScriptingCommand]) -> String {
        let commandNames = commands.map { cmd in
            var entry = cmd.name
            if let desc = cmd.description, !desc.isEmpty {
                entry += " — \(desc)"
            }
            return entry
        }
        
        let schema: [String: Any] = [
            "name": sanitize(app),
            "description": "AppleScript automation for \(app) — \(commands.count) commands available",
            "app": app,
            "strategy": "applescript",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "enum": commands.map { $0.name },
                        "description": "The AppleScript command to execute. Available commands: \n- " + commandNames.joined(separator: "\n- ")
                    ],
                    "parameters": [
                        "type": "object",
                        "description": "Command-specific parameters as key-value pairs. For the 'direct' parameter, use key 'direct'."
                    ]
                ] as [String: Any],
                "required": ["command"]
            ] as [String: Any],
            "commands": commands.map { cmd in
                [
                    "name": cmd.name,
                    "description": cmd.description ?? cmd.name,
                    "parameters": cmd.parameters.map { p in
                        [
                            "name": p.name,
                            "type": p.type,
                            "required": !p.isOptional,
                            "description": p.description ?? ""
                        ] as [String: Any]
                    },
                    "hasResult": cmd.hasResult
                ] as [String: Any]
            }
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    
    private func buildIntentSchema(intent: DiscoveredIntent) -> String {
        let schema: [String: Any] = [
            "name": intent.intentName, "description": intent.description,
            "app": intent.appName, "strategy": "appintent",
            "inputSchema": [
                "type": "object",
                "properties": intent.parameters.map { [$0.name: ["type": $0.type, "description": $0.description]] },
                "required": intent.parameters.filter { $0.isRequired }.map { $0.name }
            ]
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    
    private func mapType(_ t: String) -> String {
        switch t.lowercased() {
        case "text", "string": return "string"
        case "integer", "number": return "number"
        case "boolean": return "boolean"
        default: return "string"
        }
    }
    
    private func sanitize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "_")
         .replacingOccurrences(of: "'", with: "")
         .replacingOccurrences(of: "\"", with: "")
    }
}
