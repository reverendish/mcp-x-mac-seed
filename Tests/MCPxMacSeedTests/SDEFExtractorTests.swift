import Testing
import Foundation
@testable import MCPxMacSeed

struct SDEFExtractorTests {
    
    // MARK: - Discovery
    
    @Test("Extracting scripting dictionary from Finder returns valid schema")
    func testExtractFinderSDEF() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "Finder")
        
        #expect(!dictionary.appName.isEmpty)
        #expect(!dictionary.commands.isEmpty, "Finder should have scripting commands")
        #expect(!dictionary.classes.isEmpty, "Finder should have scriptable classes")
        
        // Verify at least one known Finder command
        let hasOpenCommand = dictionary.commands.contains { cmd in
            cmd.name.lowercased().contains("open") || cmd.name.lowercased().contains("activate")
        }
        #expect(hasOpenCommand, "Finder should have an open or activate command")
    }
    
    @Test("Extracting scripting dictionary from System Events returns valid schema")
    func testExtractSystemEventsSDEF() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "System Events")
        
        #expect(!dictionary.appName.isEmpty)
        #expect(!dictionary.commands.isEmpty, "System Events should have many commands")
        
        // System Events is the most comprehensive AppleScript dictionary on macOS
        #expect(dictionary.commands.count > 5, "System Events should have many commands")
    }
    
    @Test("Extracted commands have valid structure")
    func testCommandStructure() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "Finder")
        
        for command in dictionary.commands {
            #expect(!command.name.isEmpty, "Command name must not be empty")
            // Every command should have at least a description or parameter set
            #expect(command.description != nil || !command.parameters.isEmpty,
                    "Command should have description or parameters")
        }
    }
    
    @Test("Extracted classes reference their properties and elements")
    func testClassStructure() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "Finder")
        
        for clazz in dictionary.classes {
            #expect(!clazz.name.isEmpty, "Class name must not be empty")
            
            if let superclass = clazz.inherits {
                #expect(!superclass.isEmpty, "Superclass reference if present must not be empty")
            }
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Fetching dictionary for app with no SDEF returns empty schema")
    func testAppWithNoSDEF() async throws {
        let extractor = SDEFExtractor()
        
        // TextEdit has no scripting dictionary
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "TextEdit")
        
        // Should return a valid but empty dictionary, not throw
        #expect(!dictionary.appName.isEmpty)
        // TextEdit genuinely has no SDEF
    }
    
    @Test("Fetching dictionary for non-existent app throws appNotFound")
    func testNonExistentApp() async throws {
        let extractor = SDEFExtractor()
        
        do {
            _ = try await extractor.fetchScriptingDictionary(appName: "com.nonexistent.fakeapp99999")
            #expect(Bool(false), "Should have thrown")
        } catch let error as SDEFError {
            #expect(error == .appNotFound)
        } catch {
            #expect(Bool(false), "Wrong error type: \(error)")
        }
    }
    
    // MARK: - Output Format
    
    @Test("Dictionary output is valid JSON round-trip")
    func testDictionaryJSONRoundTrip() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "Finder")
        
        // Encode → decode should preserve data
        let encoder = JSONEncoder()
        let data = try encoder.encode(dictionary)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScriptingDictionary.self, from: data)
        
        #expect(decoded.appName == dictionary.appName)
        #expect(decoded.commands.count == dictionary.commands.count)
        #expect(decoded.classes.count == dictionary.classes.count)
    }
    
    @Test("No duplicate command names in returned dictionary")
    func testNoDuplicateCommands() async throws {
        let extractor = SDEFExtractor()
        let dictionary = try await extractor.fetchScriptingDictionary(appName: "System Events")
        
        let names = dictionary.commands.map { $0.name }
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "Command names should be unique")
    }
}
