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
            "/Applications",
            "/Applications/Utilities",
        ]
        
        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            
            for item in contents where item.hasSuffix(".app") && !item.hasPrefix(".") {
                let name = String(item.dropLast(4))
                let lower = name.lowercased()
                guard !seen.contains(lower) else { continue }
                seen.insert(lower)
                
                let path = "\(dir)/\(item)"
                
                // Strategy 1: SDEF (AppleScript — most reliable)
                let dict = try? await sdefExtractor.fetchScriptingDictionary(appName: path)
                if let sdef = dict, !sdef.commands.isEmpty {
                    let limit = min(sdef.commands.count, 25)
                    for cmd in sdef.commands.prefix(limit) where !cmd.isHidden {
                        let toolName = sanitize("\(name)_\(cmd.name)")
                        let schema = buildSDEFSchema(command: cmd, app: name)
                        _ = try? await registry.registerTool(name: toolName, app: name, schemaJSON: schema, embedding: nil)
                        count += 1
                    }
                    continue
                }
                
                // Strategy 2: AppIntents from Info.plist
                let intents = try? await intentExplorer.scanForIntents(appName: name)
                if let discovered = intents, !discovered.isEmpty {
                    for intent in discovered.prefix(10) {
                        let toolName = sanitize("\(name)_\(intent.intentName)")
                        let schema = buildIntentSchema(intent: intent)
                        _ = try? await registry.registerTool(name: toolName, app: name, schemaJSON: schema, embedding: nil)
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
    
    private func buildSDEFSchema(command: ScriptingCommand, app: String) -> String {
        var props: [[String: Any]] = []
        var reqs: [String] = []
        for p in command.parameters {
            props.append([p.name: ["type": mapType(p.type), "description": p.description ?? p.name]])
            if !p.isOptional { reqs.append(p.name) }
        }
        let schema: [String: Any] = [
            "name": command.name, "description": command.description ?? "\(command.name) via AppleScript",
            "app": app, "strategy": "applescript",
            "inputSchema": ["type": "object", "properties": props, "required": reqs]
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
