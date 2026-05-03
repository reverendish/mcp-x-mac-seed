// MCP-x-Mac Seed Server v0.1.0
// A self-evolving MCP bridge between OpenClaw and macOS AppIntents/AppleScript/Accessibility.
//
// Architecture: Recursive Meta-Compiler — the server provides discovery primitives,
// OpenClaw acts as the Wrapper and Repairman, evolving the tool registry over time.
//
// 8 seed tools:
//   1. scan_for_intents           — Discover AppIntents for any app
//   2. register_tool              — Save refined tool schemas to registry
//   3. list_registered_tools      — Query the tool registry
//   4. execute_intent             — Triple-threat execution engine
//   5. fetch_scripting_dictionary — Extract SDEF for reference-first AppleScript
//   6. get_ui_tree                — Accessibility API brute-force fallback
//   7. request_human_approval     — HITL consent gate
//   8. capture_screen_context     — Onscreen awareness (active window + displays)

print("MCP-x-Mac Seed Server v0.1.0")
print("Starting...")

try await bootstrapServer()
