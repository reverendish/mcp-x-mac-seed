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
    
    private let workspace = NSWorkspace.shared
    private let sdefPath = "/usr/bin/sdef"
    
    // MARK: - Public API
    
    /// Fetches the full scripting dictionary for a given application.
    /// Accepts bundle ID ("com.apple.finder") or display name ("Finder").
    func fetchScriptingDictionary(appName: String) async throws -> ScriptingDictionary {
        guard let appURL = resolveAppURL(appName) else {
            throw SDEFError.appNotFound
        }
        
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier
        let displayName = appURL.deletingPathExtension().lastPathComponent
        
        // Run sdef to get the XML dictionary
        let xmlString: String
        do {
            xmlString = try runSDEF(appURL: appURL)
        } catch SDEFError.sdefToolFailed, SDEFError.noScriptingDictionary {
            // App has no scripting dictionary — return empty schema
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
    
    private func resolveAppURL(_ identifier: String) -> URL? {
        // If identifier is already a path to an .app bundle, use it directly
        if identifier.hasSuffix(".app") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: identifier, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: identifier)
            }
        }
        
        if let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        
        let paths = [
            "/Applications/\(identifier).app",
            "/System/Applications/\(identifier).app",
            "/System/Library/CoreServices/\(identifier).app",
            "/Applications/Utilities/\(identifier).app",
        ]
        
        for path in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
    
    // MARK: - SDEF Execution
    
    private func runSDEF(appURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sdefPath)
        process.arguments = [appURL.path]
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        do {
            try process.run()
        } catch {
            throw SDEFError.sdefToolFailed("Failed to run sdef: \(error.localizedDescription)")
        }
        
        // Read stdout concurrently while process runs to avoid pipe buffer deadlocks
        var stdoutData = Data()
        var stderrData = Data()
        
        let readGroup = DispatchGroup()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        
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
        
        // Wait for process to exit (with timeout)
        let deadline = DispatchTime.now() + .seconds(10)
        let processGroup = DispatchGroup()
        processGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            processGroup.leave()
        }
        
        if processGroup.wait(timeout: deadline) == .timedOut {
            process.terminate()
            throw SDEFError.sdefToolFailed("sdef timed out for \(appURL.lastPathComponent)")
        }
        
        // Wait for all pipe reads to finish
        _ = readGroup.wait(timeout: .now() + .seconds(1))
        
        guard process.terminationStatus == 0 else {
            let errorMsg = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw SDEFError.sdefToolFailed("sdef exited with status \(process.terminationStatus): \(errorMsg)")
        }
        
        guard let output = String(data: stdoutData, encoding: .utf8),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SDEFError.noScriptingDictionary
        }
        
        return output
    }
    
    // MARK: - XML Parsing
    
    private func parseSDEF(xml: String, appName: String, bundleID: String?) throws -> ScriptingDictionary {
        guard let data = xml.data(using: .utf8) else {
            throw SDEFError.invalidXML
        }
        
        let parser = SDEFXMLParser()
        parser.parse(data: data)
        
        guard !parser.suites.isEmpty || !parser.commands.isEmpty || !parser.classes.isEmpty else {
            // Empty dictionary — app has no scripting support
            return ScriptingDictionary(
                appName: appName,
                appBundleID: bundleID,
                suites: [],
                commands: [],
                classes: []
            )
        }
        
        return ScriptingDictionary(
            appName: appName,
            appBundleID: bundleID,
            suites: parser.suites,
            commands: parser.commands,
            classes: parser.classes
        )
    }
}

// MARK: - XML Parser (Foundation XMLParser delegate)

private final class SDEFXMLParser: NSObject, XMLParserDelegate {
    
    var suites: [ScriptingSuite] = []
    var commands: [ScriptingCommand] = []
    var classes: [ScriptingClass] = []
    
    // Parsing state
    private var currentSuiteName = ""
    private var currentSuiteDescription: String? = nil
    private var currentSuiteCode: String? = nil
    
    private var currentCommand: MutableCommand?
    private var currentClass: MutableClass?
    private var currentProperty: MutableProperty?
    private var currentParameter: MutableParameter?
    private var isDirectParameter = false
    
    private var elementText = ""
    
    struct MutableCommand {
        var name = ""
        var code: String? = nil
        var description: String? = nil
        var suite = ""
        var parameters: [ScriptingParameter] = []
        var hasResult = false
        var resultType: String? = nil
        var resultDescription: String? = nil
        var isHidden = false
    }
    
    struct MutableClass {
        var name = ""
        var code: String? = nil
        var description: String? = nil
        var inherits: String? = nil
        var plural: String? = nil
        var suite = ""
        var properties: [ScriptingProperty] = []
        var elements: [String] = []
    }
    
    struct MutableProperty {
        var name = ""
        var code: String? = nil
        var type = ""
        var description: String? = nil
        var access: String? = nil
    }
    
    struct MutableParameter {
        var name = ""
        var code: String? = nil
        var type = ""
        var description: String? = nil
        var isOptional = false
        var isDirectParameter = false
    }
    
    func parse(data: Data) {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()
    }
    
    // MARK: - Delegate Methods
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        elementText = ""
        
        switch elementName {
        case "suite":
            currentSuiteName = attributes["name"] ?? ""
            currentSuiteDescription = attributes["description"]
            currentSuiteCode = attributes["code"]
            
        case "command":
            currentCommand = MutableCommand()
            currentCommand?.name = attributes["name"] ?? ""
            currentCommand?.code = attributes["code"]
            currentCommand?.description = attributes["description"]
            currentCommand?.suite = currentSuiteName
            if attributes["hidden"] == "yes" {
                currentCommand?.isHidden = true
            }
            
        case "class":
            currentClass = MutableClass()
            currentClass?.name = attributes["name"] ?? ""
            currentClass?.code = attributes["code"]
            currentClass?.description = attributes["description"]
            currentClass?.inherits = attributes["inherits"]
            currentClass?.plural = attributes["plural"]
            currentClass?.suite = currentSuiteName
            
        case "direct-parameter":
            isDirectParameter = true
            currentParameter = MutableParameter()
            currentParameter?.name = "direct"
            currentParameter?.type = attributes["type"] ?? "any"
            currentParameter?.description = attributes["description"]
            currentParameter?.isOptional = attributes["optional"] == "yes"
            currentParameter?.isDirectParameter = true
            
        case "parameter":
            isDirectParameter = false
            currentParameter = MutableParameter()
            currentParameter?.name = attributes["name"] ?? ""
            currentParameter?.code = attributes["code"]
            currentParameter?.type = attributes["type"] ?? "any"
            currentParameter?.description = attributes["description"]
            currentParameter?.isOptional = attributes["optional"] == "yes"
            
        case "result":
            if var cmd = currentCommand {
                cmd.hasResult = true
                cmd.resultType = attributes["type"]
                cmd.resultDescription = attributes["description"]
                currentCommand = cmd
            }
            
        case "property":
            currentProperty = MutableProperty()
            currentProperty?.name = attributes["name"] ?? ""
            currentProperty?.code = attributes["code"]
            currentProperty?.type = attributes["type"] ?? "any"
            currentProperty?.description = attributes["description"]
            currentProperty?.access = attributes["access"]
            
        case "element":
            if let type = attributes["type"] {
                currentClass?.elements.append(type)
            }
            
        case "access-group":
            // Ignore access control metadata
            break
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        
        switch elementName {
        case "suite":
            suites.append(ScriptingSuite(
                name: currentSuiteName,
                description: currentSuiteDescription,
                code: currentSuiteCode
            ))
            currentSuiteName = ""
            currentSuiteDescription = nil
            currentSuiteCode = nil
            
        case "command":
            if let cmd = currentCommand {
                commands.append(ScriptingCommand(
                    name: cmd.name,
                    code: cmd.code,
                    description: cmd.description,
                    suite: cmd.suite,
                    parameters: cmd.parameters,
                    hasResult: cmd.hasResult,
                    resultType: cmd.resultType,
                    resultDescription: cmd.resultDescription,
                    isHidden: cmd.isHidden
                ))
            }
            currentCommand = nil
            
        case "class":
            if let cls = currentClass {
                classes.append(ScriptingClass(
                    name: cls.name,
                    code: cls.code,
                    description: cls.description,
                    inherits: cls.inherits,
                    plural: cls.plural,
                    suite: cls.suite,
                    properties: cls.properties,
                    elements: cls.elements
                ))
            }
            currentClass = nil
            
        case "direct-parameter", "parameter":
            if let param = currentParameter {
                let scriptingParam = ScriptingParameter(
                    name: param.name,
                    code: param.code,
                    type: param.type,
                    description: param.description,
                    isOptional: param.isOptional,
                    isDirectParameter: param.isDirectParameter
                )
                
                if var cmd = currentCommand {
                    cmd.parameters.append(scriptingParam)
                    currentCommand = cmd
                }
            }
            currentParameter = nil
            isDirectParameter = false
            
        case "result":
            // Handled in didStartElement
            break
            
        case "property":
            if let prop = currentProperty {
                let scriptingProp = ScriptingProperty(
                    name: prop.name,
                    code: prop.code,
                    type: prop.type,
                    description: prop.description,
                    access: prop.access
                )
                currentClass?.properties.append(scriptingProp)
            }
            currentProperty = nil
            
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        elementText += string
    }
}
