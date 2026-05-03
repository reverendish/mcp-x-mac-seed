import Testing
import Foundation
@testable import MCPxMacSeed

@Suite
struct ExecutionEngineTests {

    // MARK: - AppleScript execution

    @Test("AppleScript executes successfully via osascript")
    func appleScriptExecutes() async throws {
        let engine = ExecutionEngine()
        let result = await engine.execute(
            app: "Finder",
            intentName: "activate",
            parameters: [:],
            mode: "applescript"
        )

        #expect(result.success == true)
        #expect(result.strategy == .appleScript)
        #expect(result.output != nil)
        #expect(result.error == nil)
        #expect(result.durationMs > 0)
    }

    @Test("AppleScript returns output for commands that produce output")
    func appleScriptReturnsOutput() async throws {
        let engine = ExecutionEngine()
        // "count every item of desktop" returns a number
        let result = await engine.execute(
            app: "Finder",
            intentName: "count",
            parameters: ["direct": "every item of desktop"],
            mode: "applescript"
        )

        #expect(result.success == true)
        #expect(result.strategy == .appleScript)
        // Should return the count as a string
        #expect(result.output != nil)
    }

    @Test("AppleScript for non-existent command returns failure")
    func appleScriptInvalidCommand() async throws {
        let engine = ExecutionEngine()
        let result = await engine.execute(
            app: "Finder",
            intentName: "nonexistent_command_xyz",
            parameters: [:],
            mode: "applescript"
        )

        #expect(result.success == false)
        #expect(result.strategy == .none)
    }

    // MARK: - Timeout behaviour

    @Test("Execution does not hang (completes within timeout)")
    func executionDoesNotHang() async throws {
        let engine = ExecutionEngine()
        let start = Date()

        let result = await engine.execute(
            app: "Finder",
            intentName: "activate",
            parameters: [:],
            mode: "applescript"
        )

        let elapsed = Date().timeIntervalSince(start)
        // Should complete well within the 10s subprocess timeout
        #expect(elapsed < 12.0)
        #expect(result.success == true)
    }

    // MARK: - Security blocking

    @Test("Dangerous AppleScript patterns are blocked")
    func dangerousPatternsBlocked() async throws {
        let engine = ExecutionEngine()
        // "keystroke" is in the dangerous patterns list
        let result = await engine.execute(
            app: "System Events",
            intentName: "keystroke",
            parameters: ["text": "rm -rf /"],
            mode: "applescript"
        )

        // Should be blocked at the pattern check — never reaches osascript
        #expect(result.success == false)
        #expect(result.strategy == .none)
        // Should fail fast (not blocked by timeout)
        #expect(result.durationMs < 500)
    }

    // MARK: - Strategy fallback

    @Test("Strategy: appintent mode tries AppIntents first, falls back")
    func autoModeFallsBackWhenAppIntentUnavailable() async throws {
        let engine = ExecutionEngine()
        // Use a bogus intent name — AppIntent won't find it, AppleScript will try and fail
        let result = await engine.execute(
            app: "Finder",
            intentName: "activate",  // valid for AppleScript
            parameters: [:],
            mode: "auto"
        )

        #expect(result.success == true)
        // Should have fallen through to AppleScript
        #expect(result.strategy == .appleScript)
    }

    // MARK: - ExecutionResult Codable

    @Test("ExecutionResult encodes and decodes correctly")
    func executionResultCodable() throws {
        let success = ExecutionResult(
            success: true,
            strategy: .appleScript,
            output: "Hello World",
            error: nil,
            durationMs: 42.0
        )

        let data = try JSONEncoder().encode(success)
        let decoded = try JSONDecoder().decode(ExecutionResult.self, from: data)

        #expect(decoded.success == true)
        #expect(decoded.strategy == .appleScript)
        #expect(decoded.output == "Hello World")
        #expect(decoded.error == nil)
        #expect(decoded.durationMs == 42.0)
    }

    @Test("ExecutionResult failure encodes correctly")
    func executionResultFailureCodable() throws {
        let failure = ExecutionResult(
            success: false,
            strategy: .none,
            output: nil,
            error: "All strategies exhausted",
            durationMs: 100.0
        )

        let data = try JSONEncoder().encode(failure)
        let decoded = try JSONDecoder().decode(ExecutionResult.self, from: data)

        #expect(decoded.success == false)
        #expect(decoded.strategy == .none)
        #expect(decoded.output == nil)
        #expect(decoded.error == "All strategies exhausted")
    }
}
