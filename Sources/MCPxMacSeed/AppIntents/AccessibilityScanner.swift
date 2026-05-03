import Foundation
import AppKit

// MARK: - Data Models

/// A snapshot of an application's UI accessibility tree.
struct UIAccessibilityTree: Codable, Sendable, Equatable {
    let appName: String
    let appBundleID: String?
    let rootElement: UIAccessibilityElement?
    let captureTime: String
    
    /// Returns all elements matching the given accessibility role.
    func elements(matching role: String) -> [UIAccessibilityElement] {
        guard let root = rootElement else { return [] }
        var results: [UIAccessibilityElement] = []
        collectElements(root, matching: role, into: &results)
        return results
    }
    
    private func collectElements(_ element: UIAccessibilityElement, matching role: String, into results: inout [UIAccessibilityElement]) {
        if element.role == role {
            results.append(element)
        }
        for child in element.children {
            collectElements(child, matching: role, into: &results)
        }
    }
}

/// A single element in the accessibility tree.
struct UIAccessibilityElement: Codable, Sendable, Equatable {
    let role: String
    let subrole: String?
    let title: String?
    let description: String?
    let value: String?
    let identifier: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isEnabled: Bool
    let isFocused: Bool
    let children: [UIAccessibilityElement]
    let actions: [String]
}

// MARK: - Errors

enum AccessibilityError: Error, Equatable {
    case appNotFound
    case permissionDenied
    case appNotRunning
    case traversalFailed(String)
}

// MARK: - Accessibility Scanner

/// Scans the UI accessibility tree of running macOS applications
/// using the Accessibility API (AXUIElement).
/// Serves as the brute-force fallback when AppIntents and AppleScript are unavailable.
actor AccessibilityScanner {
    
    private let workspace = NSWorkspace.shared
    
    // MARK: - Public API
    
    /// Returns the full accessibility UI tree for a running application.
    /// - Parameters:
    ///   - appName: Bundle ID or display name of the application
    ///   - maxDepth: Maximum depth to traverse (default 10, prevents runaway on complex UIs)
    func getUITree(appName: String, maxDepth: Int = 10) throws -> UIAccessibilityTree {
        guard let appURL = resolveAppURL(appName) else {
            return UIAccessibilityTree(
                appName: appName,
                appBundleID: nil,
                rootElement: nil,
                captureTime: ISO8601DateFormatter().string(from: Date())
            )
        }
        
        let bundle = Bundle(url: appURL)
        let bundleID = bundle?.bundleIdentifier
        let displayName = appURL.deletingPathExtension().lastPathComponent
        
        // Find the running application process
        guard let app = findRunningApp(bundleID: bundleID, name: displayName) else {
            return UIAccessibilityTree(
                appName: displayName,
                appBundleID: bundleID,
                rootElement: nil,
                captureTime: ISO8601DateFormatter().string(from: Date())
            )
        }
        
        // Create AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        
        // Accessibility permission check is handled implicitly by the AX API.
        // If permission is denied, AX calls will return error codes — we handle those gracefully
        // in the traversal rather than blocking at the start.
        
        // Get the root element tree
        let rootElement = try traverseElement(axApp, depth: 0, maxDepth: maxDepth)
        
        return UIAccessibilityTree(
            appName: displayName,
            appBundleID: bundleID,
            rootElement: rootElement,
            captureTime: ISO8601DateFormatter().string(from: Date())
        )
    }
    
    // MARK: - App Resolution
    
    private func resolveAppURL(_ identifier: String) -> URL? {
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
    
    private func findRunningApp(bundleID: String?, name: String) -> NSRunningApplication? {
        let apps = workspace.runningApplications
        
        // Try bundle ID match first
        if let bid = bundleID {
            if let match = apps.first(where: { $0.bundleIdentifier == bid }) {
                return match
            }
        }
        
        // Fall back to localized name match
        return apps.first { app in
            app.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
    
    // MARK: - Element Traversal
    
    private func traverseElement(_ axElement: AXUIElement, depth: Int, maxDepth: Int) throws -> UIAccessibilityElement? {
        guard depth <= maxDepth else { return nil }
        
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        var title: CFTypeRef?
        var description: CFTypeRef?
        var value: CFTypeRef?
        var identifier: CFTypeRef?
        var position: CFTypeRef?
        var size: CFTypeRef?
        var enabled: CFTypeRef?
        var focused: CFTypeRef?
        var children: CFTypeRef?
        
        // Get action names using the dedicated API (returns CFArray of CFString)
        var cfActionNames: CFArray?
        
        // Get standard properties
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole)
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(axElement, kAXDescriptionAttribute as CFString, &description)
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value)
        AXUIElementCopyAttributeValue(axElement, kAXIdentifierAttribute as CFString, &identifier)
        AXUIElementCopyAttributeValue(axElement, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(axElement, kAXSizeAttribute as CFString, &size)
        AXUIElementCopyAttributeValue(axElement, kAXEnabledAttribute as CFString, &enabled)
        AXUIElementCopyAttributeValue(axElement, kAXFocusedAttribute as CFString, &focused)
        AXUIElementCopyAttributeValue(axElement, kAXChildrenAttribute as CFString, &children)
        AXUIElementCopyActionNames(axElement, &cfActionNames)
        
        // Parse position
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        
        if let pos = position {
            var point = CGPoint.zero
            if AXValueGetValue(pos as! AXValue, .cgPoint, &point) {
                x = Double(point.x)
                y = Double(point.y)
            }
        }
        
        if let sz = size {
            var cgSize = CGSize.zero
            if AXValueGetValue(sz as! AXValue, .cgSize, &cgSize) {
                w = Double(cgSize.width)
                h = Double(cgSize.height)
            }
        }
        
        // Parse children
        var childElements: [UIAccessibilityElement] = []
        if let childrenArray = children as? [AXUIElement], depth < maxDepth {
            for child in childrenArray {
                if let childElement = try? traverseElement(child, depth: depth + 1, maxDepth: maxDepth) {
                    childElements.append(childElement)
                }
            }
        }
        
        // Parse actions
        let actions: [String] = (cfActionNames as? [String]) ?? []
        
        // No manual CF release needed — Swift ARC handles the bridging
        // The Copy functions transfer ownership; we just bridge to Swift types
        
        return UIAccessibilityElement(
            role: (role as? String) ?? "unknown",
            subrole: subrole as? String,
            title: title as? String,
            description: description as? String,
            value: value as? String,
            identifier: identifier as? String,
            x: x,
            y: y,
            width: w,
            height: h,
            isEnabled: (enabled as? Bool) ?? false,
            isFocused: (focused as? Bool) ?? false,
            children: childElements,
            actions: actions
        )
    }
}
