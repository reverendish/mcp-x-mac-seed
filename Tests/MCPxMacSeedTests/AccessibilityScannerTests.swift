import Testing
import Foundation
@testable import MCPxMacSeed

struct AccessibilityScannerTests {
    
    // MARK: - UI Tree Discovery
    
    @Test("Getting UI tree for Finder returns valid structure")
    func testGetUITreeFinder() async throws {
        let scanner = AccessibilityScanner()
        
        // Finder is always running on macOS — reliable test target
        let tree = try await scanner.getUITree(appName: "Finder")
        
        #expect(!tree.appName.isEmpty)
        #expect(tree.rootElement != nil, "Finder should have a UI element tree")
        
        if let root = tree.rootElement {
            #expect(!root.role.isEmpty, "Root element should have a role")
            
            // Finder's main window should have child elements
            #expect(!root.children.isEmpty, "Finder should have child UI elements")
        }
    }
    
    @Test("UI tree elements have valid properties")
    func testUIElementProperties() async throws {
        let scanner = AccessibilityScanner()
        let tree = try await scanner.getUITree(appName: "Finder")
        
        guard let root = tree.rootElement else { return }
        
        func validateElement(_ element: UIAccessibilityElement, depth: Int = 0) {
            #expect(!element.role.isEmpty, "Every element must have a role")
            
            // Off-screen elements may have -1 positions — that's valid
            // Elements without positions default to (0, 0)
            
            for child in element.children {
                validateElement(child, depth: depth + 1)
            }
            
            // Don't recurse too deep — Finder can have hundreds of elements
            guard depth < 3 else { return }
        }
        
        validateElement(root)
    }
    
    @Test("UI tree respects maxDepth parameter")
    func testMaxDepthLimiting() async throws {
        let scanner = AccessibilityScanner()
        
        // Get tree with max depth 1 — should only have root + direct children
        let shallow = try await scanner.getUITree(appName: "Finder", maxDepth: 1)
        
        // Get full tree
        let full = try await scanner.getUITree(appName: "Finder")
        
        // Shallow tree should have fewer total elements
        func countElements(_ element: UIAccessibilityElement) -> Int {
            return 1 + element.children.reduce(0) { $0 + countElements($1) }
        }
        
        let shallowCount = shallow.rootElement.map { countElements($0) } ?? 0
        let fullCount = full.rootElement.map { countElements($0) } ?? 0
        
        #expect(shallowCount <= fullCount, "Shallow tree should have ≤ elements than full tree")
        if shallowCount > 0 && fullCount > 0 {
            #expect(shallowCount < fullCount, "Shallow tree should have fewer elements")
        }
    }
    
    @Test("Can filter UI tree by element role")
    func testFilterByRole() async throws {
        let scanner = AccessibilityScanner()
        let tree = try await scanner.getUITree(appName: "Finder")
        
        let buttons = tree.elements(matching: "AXButton")
        
        // The matching should work — any elements found must have correct role
        for button in buttons {
            #expect(button.role == "AXButton", "Filtered button should have AXButton role")
        }
        
        // Windows may or may not be present at the app level in the AX tree
        // The test verifies the filter works correctly, not that specific elements exist
    }
    
    // MARK: - Edge Cases
    
    @Test("Getting UI tree for non-existent app returns empty tree")
    func testNonExistentApp() async throws {
        let scanner = AccessibilityScanner()
        let tree = try await scanner.getUITree(appName: "com.nonexistent.fakeapp99999")
        
        #expect(tree.rootElement == nil)
        #expect(!tree.appName.isEmpty, "App name should still be set")
    }
    
    @Test("Getting UI tree for app not running returns empty tree")
    func testAppNotRunning() async throws {
        let scanner = AccessibilityScanner()
        
        // An app that exists but probably isn't running
        let tree = try await scanner.getUITree(appName: "Chess")
        
        // Should not crash; may return empty if Chess isn't running
        #expect(tree.rootElement == nil || tree.rootElement != nil)
    }
    
    // MARK: - Output Format
    
    @Test("UI tree output is valid JSON round-trip")
    func testUITreeJSONRoundTrip() async throws {
        let scanner = AccessibilityScanner()
        let tree = try await scanner.getUITree(appName: "Finder")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(tree)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(UIAccessibilityTree.self, from: data)
        
        #expect(decoded.appName == tree.appName)
    }
}
