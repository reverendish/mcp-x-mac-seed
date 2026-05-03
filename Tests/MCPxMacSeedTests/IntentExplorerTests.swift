import Testing
import Foundation
@testable import MCPxMacSeed

struct IntentExplorerTests {
    
    // MARK: - Discovery
    
    @Test("Scanning a known Apple app returns intents when available")
    func testScanKnownApp() async throws {
        let explorer = IntentExplorer()
        let intents = try await explorer.scanForIntents(appName: "Mail")
        
        // Mail.app may or may not expose AppIntents via Info.plist in this macOS version.
        // The test verifies the scan completes without error regardless.
        
        // Verify structure of any returned intents
        for intent in intents {
            #expect(!intent.intentName.isEmpty, "Intent name must not be empty")
            #expect(!intent.description.isEmpty, "Intent description must not be empty")
            #expect(!intent.appName.isEmpty, "App name must not be empty")
        }
    }
    
    @Test("Scanned intent parameters have valid structure")
    func testIntentParameterStructure() async throws {
        let explorer = IntentExplorer()
        let intents = try await explorer.scanForIntents(appName: "Notes")
        
        guard let firstIntent = intents.first else {
            // Notes might not have intents on every version — skip gracefully
            return
        }
        
        // Every parameter should have name and type
        for param in firstIntent.parameters {
            #expect(!param.name.isEmpty, "Parameter name must not be empty")
            #expect(!param.type.isEmpty, "Parameter type must not be empty")
            // description can be empty for simple params, but should exist
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Scanning a non-existent app returns empty array, not error")
    func testScanNonExistentApp() async throws {
        let explorer = IntentExplorer()
        let intents = try await explorer.scanForIntents(appName: "com.nonexistent.fakeapp123")
        #expect(intents.isEmpty)
    }
    
    @Test("Scanning by display name matches bundle ID fuzzy")
    func testScanByDisplayName() async throws {
        let explorer = IntentExplorer()
        
        // "Mail" should match com.apple.mail
        let byDisplay = try await explorer.scanForIntents(appName: "Mail")
        let byBundle = try await explorer.scanForIntents(appName: "com.apple.mail")
        
        // Both should find the same app
        #expect(byDisplay.count == byBundle.count)
    }
    
    @Test("Scanning an app with no intents returns empty array")
    func testScanAppWithNoIntents() async throws {
        let explorer = IntentExplorer()
        
        // Many system utilities have no AppIntents
        let intents = try await explorer.scanForIntents(appName: "com.apple.airport.airportutility")
        // Should not crash, just return empty
        #expect(intents.isEmpty)
    }
    
    // MARK: - Output Format
    
    @Test("Returned intent JSON is valid and can be re-encoded")
    func testIntentOutputIsValidJSON() async throws {
        let explorer = IntentExplorer()
        let intents = try await explorer.scanForIntents(appName: "Mail")
        
        guard !intents.isEmpty else { return }
        
        // Verify we can encode → decode without loss
        let encoder = JSONEncoder()
        let data = try encoder.encode(intents)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([DiscoveredIntent].self, from: data)
        
        #expect(decoded.count == intents.count)
        #expect(decoded.first?.intentName == intents.first?.intentName)
    }
    
    @Test("No duplicate intent names in returned list")
    func testNoDuplicateIntents() async throws {
        let explorer = IntentExplorer()
        let intents = try await explorer.scanForIntents(appName: "Mail")
        
        let names = intents.map { $0.intentName }
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "Intent names should be unique")
    }
}
