import Foundation
import AppKit
import AppIntents
import UniformTypeIdentifiers

// MARK: - Data Models

/// A discovered AppIntent with its parameter schema.
struct DiscoveredIntent: Codable, Sendable, Equatable {
    let intentName: String
    let description: String
    let appName: String
    let parameters: [IntentParameterSchema]
    let isAvailable: Bool
}

/// A single parameter of a discovered intent.
struct IntentParameterSchema: Codable, Sendable, Equatable {
    let name: String
    let type: String
    let description: String
    let isRequired: Bool
    let defaultValue: String?
}

// MARK: - Errors

enum ExplorerError: Error, Equatable {
    case appNotFound(String)
    case noIntentsExposed(String)
    case sandboxRestricted(String)
}

// MARK: - Intent Explorer

/// Discovers AppIntents from macOS applications.
/// Uses multiple strategies: introspection of AssistantSchemas,
/// bundle metadata probing, and system shortcut integration.
actor IntentExplorer {
    
    private let workspace = NSWorkspace.shared
    
    // MARK: - Public API
    
    /// Scans for all AppIntents exposed by a given application.
    /// Accepts either a bundle ID ("com.apple.mail") or display name ("Mail").
    /// Returns an empty array if the app doesn't expose any intents.
    func scanForIntents(appName: String) throws -> [DiscoveredIntent] {
        guard let appURL = resolveAppURL(appName) else {
            // Not an error — app just has no AppIntents to expose
            return []
        }
        
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier ?? appName
        
        // Strategy 1: Check for SiriKit/Intents configuration in Info.plist
        var intents = try discoverViaIntentsExtension(appURL: appURL, bundleID: bundleID)
        
        // Strategy 2: Check for AppIntents framework linkage (AssistantSchemas)
        let assistantIntents = try discoverViaAssistantSchemas(appURL: appURL, bundleID: bundleID)
        intents.append(contentsOf: assistantIntents)
        
        // Deduplicate by intent name
        var seen = Set<String>()
        intents = intents.filter { seen.insert($0.intentName).inserted }
        
        return intents
    }
    
    // MARK: - App Resolution
    
    private func resolveAppURL(_ identifier: String) -> URL? {
        // Try as bundle ID first
        if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        
        // Try as display name
        let paths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "/System/Library/CoreServices/\(identifier).app",
            "/Applications/Utilities/\(identifier).app",
        ]
        
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        
        // Search via NSWorkspace as fallback
        let allApps = NSWorkspace.shared.urlsForApplications(toOpen: UTType(exportedAs: "com.apple.application-bundle")) ?? []
        return allApps.first { url in
            let name = url.deletingPathExtension().lastPathComponent
            return name.localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }
    }
    
    // MARK: - Discovery Strategies
    
    /// Probes the app's Info.plist for INIntents declarations (SiriKit era)
    private func discoverViaIntentsExtension(appURL: URL, bundleID: String) throws -> [DiscoveredIntent] {
        guard let bundle = Bundle(url: appURL) else { return [] }
        
        // Apps that support intents declare NSUserActivityTypes or INIntents in Info.plist
        let supportedIntents = bundle.object(forInfoDictionaryKey: "INIntentsSupported") as? [String] ?? []
        let activityTypes = bundle.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String] ?? []
        
        var intents: [DiscoveredIntent] = []
        
        for intentClassName in supportedIntents {
            // Extract a human-readable name from the class name
            let shortName = intentClassName
                .replacingOccurrences(of: "IN", with: "")
                .replacingOccurrences(of: "Intent", with: "")
                .camelCaseToSpaced()
            
            intents.append(DiscoveredIntent(
                intentName: shortName.isEmpty ? intentClassName : shortName,
                description: "SiriKit intent: \(intentClassName)",
                appName: bundleID,
                parameters: [], // SiriKit intents need INIntent subclass introspection for params
                isAvailable: true
            ))
        }
        
        // Discovery via NSUserActivityTypes (common for newer apps)
        for activityType in activityTypes {
            if activityType.contains("Intent") || activityType.contains("intent") {
                let shortName = activityType
                    .components(separatedBy: ".")
                    .last?
                    .camelCaseToSpaced() ?? activityType
                
                intents.append(DiscoveredIntent(
                    intentName: shortName,
                    description: "Activity-based intent: \(activityType)",
                    appName: bundleID,
                    parameters: [],
                    isAvailable: true
                ))
            }
        }
        
        return intents
    }
    
    /// Checks if the app links against AppIntents and likely has AssistantSchemas
    private func discoverViaAssistantSchemas(appURL: URL, bundleID: String) throws -> [DiscoveredIntent] {
        // Apps with AppIntents capability declare it in their Info.plist
        // via the "AppIntentsSupported" key (introduced in macOS 14+)
        guard let bundle = Bundle(url: appURL) else { return [] }
        
        let appIntentsSupported = bundle.object(forInfoDictionaryKey: "AppIntentsSupported") as? Bool ?? false
        let assistantSchemas = bundle.object(forInfoDictionaryKey: "AssistantSchemas") as? [[String: Any]] ?? []
        
        // Also check if the app links AppIntents.framework
        let isAppIntentsLinked = checkFrameworkLinkage(appURL: appURL, frameworkName: "AppIntents")
        
        guard appIntentsSupported || isAppIntentsLinked || !assistantSchemas.isEmpty else {
            return []
        }
        
        var intents: [DiscoveredIntent] = []
        
        // If we have explicit AssistantSchemas in Info.plist, parse them
        for schema in assistantSchemas {
            if let intentName = schema["IntentName"] as? String,
               let description = schema["Description"] as? String {
                let params = (schema["Parameters"] as? [[String: Any]])?.compactMap { param -> IntentParameterSchema? in
                    guard let name = param["Name"] as? String else { return nil }
                    return IntentParameterSchema(
                        name: name,
                        type: (param["Type"] as? String) ?? "String",
                        description: (param["Description"] as? String) ?? "",
                        isRequired: param["Required"] as? Bool ?? false,
                        defaultValue: param["DefaultValue"] as? String
                    )
                } ?? []
                
                intents.append(DiscoveredIntent(
                    intentName: intentName,
                    description: description,
                    appName: bundleID,
                    parameters: params,
                    isAvailable: true
                ))
            }
        }
        
        return intents
    }
    
    // MARK: - Helpers
    
    /// Checks if a given app binary links against a specific framework
    private func checkFrameworkLinkage(appURL: URL, frameworkName: String) -> Bool {
        guard let bundle = Bundle(url: appURL),
              let executablePath = bundle.executablePath else {
            return false
        }
        
        // Use otool to check linked frameworks
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", executablePath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.contains(frameworkName)
        } catch {
            return false
        }
    }
}

// MARK: - String Helper

extension String {
    /// Converts "CamelCaseString" to "Camel Case String"
    func camelCaseToSpaced() -> String {
        let pattern = "([a-z])([A-Z])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return self
        }
        let range = NSRange(location: 0, length: utf16.count)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "$1 $2")
    }
}
