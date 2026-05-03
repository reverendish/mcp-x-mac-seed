import Foundation
import AppKit
import CoreGraphics

// MARK: - Data Models

/// A snapshot of the current screen context — what the user is looking at.
struct ScreenContextInfo: Codable, Sendable, Equatable {
    let timestamp: String
    let activeApplication: ActiveAppInfo
    let activeWindow: ActiveWindowInfo?
    let displays: [DisplayInfo]
    let ocrText: String?
}

/// Information about the currently active application.
struct ActiveAppInfo: Codable, Sendable, Equatable {
    let name: String
    let bundleIdentifier: String?
    let processIdentifier: Int32
}

/// Information about the currently focused window.
struct ActiveWindowInfo: Codable, Sendable, Equatable {
    let title: String?
    let ownerName: String
    let ownerBundleID: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let windowLayer: Int32
}

/// Display information.
struct DisplayInfo: Codable, Sendable, Equatable {
    let id: UInt32
    let width: Double
    let height: Double
    let isMain: Bool
}

// MARK: - Screen Context

/// Captures the current screen context using Quartz Window Server and CoreGraphics.
/// Provides "eyes" for the agent — what app is active, what window is focused,
/// display configuration, and optionally OCR text from the active window.
actor ScreenContext {
    
    // MARK: - Public API
    
    /// Captures the current screen context.
    /// - Parameter includeOCR: Whether to run OCR on the active window (default false for speed)
    func captureScreenContext(includeOCR: Bool = false) throws -> ScreenContextInfo {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let activeApp = captureActiveApplication()
        let activeWindow = captureActiveWindow()
        let displays = captureDisplays()
        let ocrText: String? = includeOCR ? captureOCRText() : nil
        
        return ScreenContextInfo(
            timestamp: timestamp,
            activeApplication: activeApp,
            activeWindow: activeWindow,
            displays: displays,
            ocrText: ocrText
        )
    }
    
    // MARK: - Active Application
    
    private func captureActiveApplication() -> ActiveAppInfo {
        if let app = NSWorkspace.shared.frontmostApplication {
            return ActiveAppInfo(
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                processIdentifier: app.processIdentifier
            )
        }
        
        return ActiveAppInfo(
            name: "Unknown",
            bundleIdentifier: nil,
            processIdentifier: 0
        )
    }
    
    // MARK: - Active Window
    
    private func captureActiveWindow() -> ActiveWindowInfo? {
        // Get list of all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        
        // Find the frontmost window from the active application
        let activeApp = NSWorkspace.shared.frontmostApplication
        let activeBundleID = activeApp?.bundleIdentifier
        
        // Filter windows by the active app's bundle ID
        let appWindows = windowList.filter { window in
            if let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
               let activePID = activeApp?.processIdentifier {
                return ownerPID == activePID
            }
            return false
        }
        
        // Get the frontmost window (lowest window layer = frontmost)
        let frontWindow = appWindows.min { a, b in
            let layerA = a[kCGWindowLayer as String] as? Int32 ?? Int32.max
            let layerB = b[kCGWindowLayer as String] as? Int32 ?? Int32.max
            return layerA < layerB
        }
        
        guard let window = frontWindow else { return nil }
        
        // Parse window bounds
        let bounds = window[kCGWindowBounds as String] as? [String: Any]
        let x = (bounds?["X"] as? Double) ?? 0
        let y = (bounds?["Y"] as? Double) ?? 0
        let w = (bounds?["Width"] as? Double) ?? 0
        let h = (bounds?["Height"] as? Double) ?? 0
        let layer = window[kCGWindowLayer as String] as? Int32 ?? 0
        
        return ActiveWindowInfo(
            title: window[kCGWindowName as String] as? String,
            ownerName: window[kCGWindowOwnerName as String] as? String ?? "Unknown",
            ownerBundleID: activeBundleID,
            x: x,
            y: y,
            width: w,
            height: h,
            windowLayer: layer
        )
    }
    
    // MARK: - Displays
    
    private func captureDisplays() -> [DisplayInfo] {
        var displays: [DisplayInfo] = []
        var displayCount: UInt32 = 0
        
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else {
            return []
        }
        
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }
        
        let mainDisplayID = CGMainDisplayID()
        
        for id in displayIDs {
            let width = Double(CGDisplayPixelsWide(id))
            let height = Double(CGDisplayPixelsHigh(id))
            
            displays.append(DisplayInfo(
                id: id,
                width: width,
                height: height,
                isMain: id == mainDisplayID
            ))
        }
        
        return displays
    }
    
    // MARK: - OCR (stub — Vision framework integration deferred)
    
    private func captureOCRText() -> String? {
        // OCR via Apple's Vision framework would go here.
        // This is deferred to a later phase — the framework linkage
        // and model initialization add significant build complexity.
        // The architecture supports it: the `ocrText` field is nullable
        // and the `includeOCR` flag gates it.
        return nil
    }
}
