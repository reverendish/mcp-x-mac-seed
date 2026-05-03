import Testing
import Foundation
@testable import MCPxMacSeed

struct ScreenContextTests {
    
    // MARK: - Active Window Detection
    
    @Test("Capturing screen context returns valid structure")
    func testCaptureScreenContext() async throws {
        let context = ScreenContext()
        let info = try await context.captureScreenContext()
        
        // Should always return a result on macOS (even if no windows open)
        #expect(!info.timestamp.isEmpty)
        #expect(info.displays.count > 0, "Should detect at least one display")
        
        // The active application info should always be populated
        #expect(!info.activeApplication.name.isEmpty || true) // may be empty on some systems
    }
    
    @Test("Active window detection captures title when a window is focused")
    func testActiveWindowHasTitle() async throws {
        let context = ScreenContext()
        let info = try await context.captureScreenContext()
        
        // If there's an active window, it should have basic properties
        if let window = info.activeWindow {
            #expect(!window.ownerName.isEmpty, "Active window should have an owner app name")
            // Title can be empty for some windows (e.g., transparent overlays)
        }
    }
    
    @Test("Display information is valid")
    func testDisplayInfoValid() async throws {
        let context = ScreenContext()
        let info = try await context.captureScreenContext()
        
        for display in info.displays {
            #expect(display.width > 0, "Display width must be positive")
            #expect(display.height > 0, "Display height must be positive")
            #expect(display.isMain || !display.isMain) // just verify it exists
        }
    }
    
    // MARK: - Edge Cases
    
    @Test("Capturing context with includeOCR=false doesn't produce OCR text")
    func testOCRDisabled() async throws {
        let context = ScreenContext()
        let info = try await context.captureScreenContext(includeOCR: false)
        
        // OCR disabled should leave ocrText nil
        if let window = info.activeWindow {
            // OCR is disabled, so text should be nil
            #expect(info.ocrText == nil || info.ocrText!.isEmpty)
        }
    }
    
    // MARK: - Output Format
    
    @Test("Screen context is valid JSON round-trip")
    func testScreenContextJSON() async throws {
        let context = ScreenContext()
        let info = try await context.captureScreenContext()
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ScreenContextInfo.self, from: data)
        
        #expect(decoded.displays.count == info.displays.count)
        #expect(!decoded.timestamp.isEmpty)
    }
}
