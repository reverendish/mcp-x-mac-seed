import Foundation
import AppKit

// MARK: - Data Models

/// A parsed scripting dictionary from an app's SDEF.
struct ScriptingDictionary: Codable, Sendable, Equatable {
    let appName: String
    let appBundleID: String?
    let suites: [ScriptingSuite]
    let commands: [ScriptingCommand]
    let classes: [ScriptingClass]
}

/// A suite grouping related commands and classes.
struct ScriptingSuite: Codable, Sendable, Equatable {
    let name: String
    let description: String?
    let code: String?
}

/// A single scripting command (e.g., "open", "make", "delete").
struct ScriptingCommand: Codable, Sendable, Equatable {
    let name: String
    let code: String?
    let description: String?
    let suite: String
    let parameters: [ScriptingParameter]
    let hasResult: Bool
    let resultType: String?
    let resultDescription: String?
    let isHidden: Bool
}

/// A parameter to a scripting command.
struct ScriptingParameter: Codable, Sendable, Equatable {
    let name: String
    let code: String?
    let type: String
    let description: String?
    let isOptional: Bool
    let isDirectParameter: Bool
}

/// A scriptable class (e.g., "folder", "file", "window").
struct ScriptingClass: Codable, Sendable, Equatable {
    let name: String
    let code: String?
    let description: String?
    let inherits: String?
    let plural: String?
    let suite: String
    let properties: [ScriptingProperty]
    let elements: [String]  // Element type names this class contains
}

/// A property of a scriptable class.
struct ScriptingProperty: Codable, Sendable, Equatable {
    let name: String
    let code: String?
    let type: String
    let description: String?
    let access: String?  // "r" for read-only, "rw" or nil for read-write
}

// MARK: - Errors

enum SDEFError: Error, Equatable {
    case appNotFound
    case sdefToolFailed(String)
    case invalidXML
    case noScriptingDictionary
}

// MARK: - SDEF Extractor

/// Extracts and parses AppleScript scripting dictionaries (.sdef files)
/// from macOS applications using the built-in `sdef` command-line tool.
actor SDEFExtractor {
    
    private let sdefPath = "/usr/bin/sdef"
    
    // MARK: - Public API
    
    /// Fetches the full scripting dictionary for a given application.
    /// Accepts bundle ID ("com.apple.finder") or display name ("Finder").
    func fetchScriptingDictionary(appName: String) async throws -> ScriptingDictionary {
        guard let appURL = await resolveAppURL(appName) else {
            throw SDEFError.appNotFound
        }
        fputs("[SDEF-DBG] resolveAppURL resolved '\(appName)'\n", stderr)
        
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier
        let displayName = appURL.deletingPathExtension().lastPathComponent
        
        // Run sdef to get the XML dictionary
        let xmlString: String
        do {
            xmlString = try await runSDEF(appURL: appURL)
        } catch {
            return ScriptingDictionary(
                appName: displayName,
                appBundleID: bundleID,
                suites: [],
                commands: [],
                classes: []
            )
        }
        
        // Parse the XML into structured data
        return try parseSDEF(xml: xmlString, appName: displayName, bundleID: bundleID)
    }
    
    // MARK: - App Resolution
    
    private func resolveAppURL(_ identifier: String) async -> URL? {
        // If identifier is already a path to an .app bundle, use it directly
        if identifier.hasSuffix(".app") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: identifier, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: identifier)
            }
        }
        
        // Try common paths first (fast, no NSWorkspace dependency)
        let commonPaths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "/System/Library/CoreServices/\(identifier).app",
            "/Applications/Utilities/\(identifier).app",
        ]
        for path in commonPaths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        
        // Fallback: use `mdfind` Spotlight search for non-standard paths
        let spotlightPath = await findAppViaSpotlight(identifier)
        return spotlightPath
    }
    
    /// Uses Spotlight to find an app path, avoiding NSWorkspace thread-safety issues.
    private func findAppViaSpotlight(_ identifier: String) async -> URL? {
        // Try as bundle ID first
        let bundleQuery = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemCFBundleIdentifier == '\(identifier)'c"
        if let url = await runSpotlight(query: bundleQuery) {
            return url
        }
        
        // Try as display name
        let nameQuery = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemFSName == '\(identifier).app'"
        return await runSpotlight(query: nameQuery)
    }
    
    /// Runs mdfind to find an app bundle path.
    private func runSpotlight(query: String) async -> URL? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", "/", query]
                
                let stdoutPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = Pipe()
                
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !output.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let firstPath = output.components(separatedBy: "\n").first ?? ""
                guard !firstPath.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: URL(fileURLWithPath: firstPath))
            }
        }
    }
    
    // MARK: - SDEF Execution
    
    /// Runs /usr/bin/sdef and captures its output using async subprocess management.
    private func runSDEF(appURL: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.sdefPath)
                process.arguments = [appURL.path]
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: SDEFError.sdefToolFailed("Failed to run sdef: \(error.localizedDescription)"))
                    return
                }
                
                // Read stdout concurrently while process runs
                let readGroup = DispatchGroup()
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading
                
                var stdoutData = Data()
                var stderrData = Data()
                
                readGroup.enter()
                DispatchQueue.global().async {
                    stdoutData = stdoutHandle.readDataToEndOfFile()
                    readGroup.leave()
                }
                
                readGroup.enter()
                DispatchQueue.global().async {
                    stderrData = stderrHandle.readDataToEndOfFile()
                    readGroup.leave()
                }
                
                // Wait for process exit (with 3s timeout)
                let deadline = DispatchTime.now() + .seconds(3)
                let processGroup = DispatchGroup()
                processGroup.enter()
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    processGroup.leave()
                }
                
                let timedOut = processGroup.wait(timeout: deadline) == .timedOut
                
                if timedOut {
                    process.terminate()
                    continuation.resume(throwing: SDEFError.sdefToolFailed("sdef timed out for \(appURL.lastPathComponent)"))
                    return
                }
                
                // Wait for pipe reads to finish
                _ = readGroup.wait(timeout: .now() + .seconds(1))
                
                guard process.terminationStatus == 0 else {
                    let errorMsg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: SDEFError.sdefToolFailed("sdef exited with status \(process.terminationStatus): \(errorMsg)"))
                    return
                }
                
                guard let output = String(data: stdoutData, encoding: .utf8),
                      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: SDEFError.noScriptingDictionary)
                    return
                }
                
                continuation.resume(returning: output)
            }
        }
    }
    
    // MARK: - XML Parsing
    
    private func parseSDEF(xml: String, appName: String, bundleID: String?) throws -> ScriptingDictionary {
        guard let data = xml.data(using: .utf8) else {
            throw SDEFError.invalidXML
        }
        
        // Parse XML using XMLDocument (NSXMLDocument) which is thread-safe
        // and doesn't need MainActor for delegate callbacks
        let doc = try XMLDocument(data: data, options: [])
        guard let root = doc.rootElement() else {
            throw SDEFError.invalidXML
        }
        
        var suites: [ScriptingSuite] = []
        var commands: [ScriptingCommand] = []
        var classes: [ScriptingClass] = []
        
        // Iterate through suite elements
        for suiteNode in root.elements(forName: "suite") {
            let suiteName = suiteNode.attributeString("name") ?? ""
            let suiteDesc = suiteNode.attributeString("description")
            let suiteCode = suiteNode.attributeString("code")
            
            suites.append(ScriptingSuite(
                name: suiteName,
                description: suiteDesc,
                code: suiteCode
            ))
            
            // Parse commands within this suite
            for cmdNode in suiteNode.elements(forName: "command") {
                let cmd = parseCommand(cmdNode, suite: suiteName)
                commands.append(cmd)
            }
            
            // Parse classes within this suite
            for clsNode in suiteNode.elements(forName: "class") {
                let cls = parseClass(clsNode, suite: suiteName)
                classes.append(cls)
            }
        }
        
        return ScriptingDictionary(
            appName: appName,
            appBundleID: bundleID,
            suites: suites,
            commands: commands,
            classes: classes
        )
    }
    
    // MARK: - XML Element Parsing Helpers
    
    private func parseCommand(_ node: XMLNode, suite: String) -> ScriptingCommand {
        let el = node as! XMLElement
        let name = el.attributeString("name") ?? ""
        let code = el.attributeString("code")
        let desc = el.attributeString("description")
        let hidden = el.attributeString("hidden") == "yes"
        
        var parameters: [ScriptingParameter] = []
        var hasResult = false
        var resultType: String? = nil
        var resultDescription: String? = nil
        
        for child in el.children ?? [] {
            guard let childEl = child as? XMLElement else { continue }
            switch childEl.name {
            case "direct-parameter":
                let p = ScriptingParameter(
                    name: "direct",
                    code: childEl.attributeString("code"),
                    type: childEl.attributeString("type") ?? "any",
                    description: childEl.attributeString("description"),
                    isOptional: childEl.attributeString("optional") == "yes",
                    isDirectParameter: true
                )
                parameters.append(p)
            case "parameter":
                let p = ScriptingParameter(
                    name: childEl.attributeString("name") ?? "",
                    code: childEl.attributeString("code"),
                    type: childEl.attributeString("type") ?? "any",
                    description: childEl.attributeString("description"),
                    isOptional: childEl.attributeString("optional") == "yes",
                    isDirectParameter: false
                )
                parameters.append(p)
            case "result":
                hasResult = true
                resultType = childEl.attributeString("type")
                resultDescription = childEl.attributeString("description")
            default:
                break
            }
        }
        
        return ScriptingCommand(
            name: name,
            code: code,
            description: desc,
            suite: suite,
            parameters: parameters,
            hasResult: hasResult,
            resultType: resultType,
            resultDescription: resultDescription,
            isHidden: hidden
        )
    }
    
    private func parseClass(_ node: XMLNode, suite: String) -> ScriptingClass {
        let el = node as! XMLElement
        let name = el.attributeString("name") ?? ""
        let code = el.attributeString("code")
        let desc = el.attributeString("description")
        let inherits = el.attributeString("inherits")
        let plural = el.attributeString("plural")
        
        var properties: [ScriptingProperty] = []
        var elements: [String] = []
        
        for child in el.children ?? [] {
            guard let childEl = child as? XMLElement else { continue }
            switch childEl.name {
            case "property":
                let p = ScriptingProperty(
                    name: childEl.attributeString("name") ?? "",
                    code: childEl.attributeString("code"),
                    type: childEl.attributeString("type") ?? "any",
                    description: childEl.attributeString("description"),
                    access: childEl.attributeString("access")
                )
                properties.append(p)
            case "element":
                if let type = childEl.attributeString("type") {
                    elements.append(type)
                }
            default:
                break
            }
        }
        
        return ScriptingClass(
            name: name,
            code: code,
            description: desc,
            inherits: inherits,
            plural: plural,
            suite: suite,
            properties: properties,
            elements: elements
        )
    }
}

// MARK: - XMLElement Helpers

private extension XMLElement {
    func attributeString(_ name: String) -> String? {
        return attribute(forName: name)?.stringValue
    }
}
