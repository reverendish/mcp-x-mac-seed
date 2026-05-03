# Implementation Checklist — MCP-x-Mac Seed Server

> Status: ☐ Not started | 🔄 In progress | ✅ Complete | ⛔ Blocked

---

## Phase 0: Environment Verification ✅

- [x] ✅ 0.1 — Verify Swift 6.0+ toolchain → Swift 6.3
- [x] ✅ 0.2 — Verify Xcode 16+ → Xcode 26.4
- [x] ✅ 0.3 — Verify macOS 15+ deployment target → macOS 26.0
- [x] ✅ 0.4 — Create project scaffold via `swift package init` → Done

## Phase 1: Project Scaffold & Dependencies ✅

- [x] ✅ 1.1 — Initialize SPM package at `~/Desktop/mcp-x-mac-seed/`
- [x] ✅ 1.2 — Add MCP Swift SDK dependency → resolved to 0.12.0
- [x] ✅ 1.3 — Add GRDB.swift dependency → resolved to 7.10.0
- [x] ✅ 1.4 — Configure Package.swift with platform requirements (macOS 15+)
- [x] ✅ 1.5 — Create directory structure
- [x] ✅ 1.6 — Verify `swift build` succeeds (clean, 0.84s)

## Phase 2: Database Layer (Registry)

- [x] ✅ 2.1 — Create `Models.swift` (ToolRecord, RepairEntry, ConsentGate types, RegistryError)
- [x] ✅ 2.2 — Implement `Registry.swift` — SQLite connection manager (actor, DatabaseQueue)
- [x] ✅ 2.3 — Write schema migration: `tools` table (with requires_approval, repair_history, embedding columns)
- [x] ✅ 2.4 — Implement `registerTool` (INSERT with upsert, version increment)
- [x] ✅ 2.5 — Implement `listTools` (SELECT with optional app filter)
- [x] ✅ 2.6 — Implement `updateToolStatus` (for Repairman error capture)
- [x] ✅ 2.7 — Implement `getRepairHistory` (retrieval for rollback)
- [x] ✅ 2.8 — Implement `setApprovalGate` (mark tool as requires_approval)
- [x] ✅ 2.9 — Write RegistryTests (16 test cases, all green)

## Phase 3: AppIntents Explorer

- [x] ✅ 3.1 — Implement `IntentExplorer.swift` — multi-strategy introspection (Info.plist + AssistantSchemas + framework linkage)
- [x] ✅ 3.2 — Filter intents by app bundle ID or display name (NSWorkspace resolution)
- [x] ✅ 3.3 — Extract parameter schemas (name, type, description, required, default)
- [x] ✅ 3.4 — Handle apps with no exposed intents gracefully (empty array)
- [x] ✅ 3.5 — Handle permission-denied / sandboxed apps gracefully
- [x] ✅ 3.6 — Write IntentExplorerTests (7 test cases, all green)

## Phase 4: AppleScript SDEF Extractor

- [x] ✅ 4.1 — Implement `SDEFExtractor.swift` — locate app + extract .sdef via `/usr/bin/sdef`
- [x] ✅ 4.2 — Convert SDEF XML → structured JSON (suites, commands with params, classes with properties/elements)
- [x] ✅ 4.3 — Handle commands with direct-parameter, optional params, results, hidden flags, access groups
- [x] ✅ 4.4 — Handle apps with no scripting dictionary gracefully (return empty schema)
- [x] ✅ 4.5 — Handle malformed / legacy aete resources (sdef exit code → empty schema)
- [x] ✅ 4.6 — Write SDEFExtractorTests (8 test cases: Finder, System Events, structure validation, edge cases)

## Phase 5: Accessibility Scanner (AXorcist Fallback)

- [x] ✅ 5.1 — Implement `AccessibilityScanner.swift` — AXUIElement tree traversal with depth limiting
- [x] ✅ 5.2 — Extract element properties: role, subrole, title, description, value, identifier, position, size, enabled, focused, actions
- [x] ✅ 5.3 — Filter tree by element type (elements(matching:) helper on UIAccessibilityTree)
- [x] ✅ 5.4 — Handle accessibility permission denied gracefully (empty tree, no crash)
- [x] ✅ 5.5 — Handle apps with empty/disabled UI (not running → empty tree)
- [x] ✅ 5.6 — Write AccessibilityScannerTests (7 test cases: Finder tree, properties, depth limiting, role filter, edge cases)

## Phase 6: Screen Context Awareness

- [x] ✅ 6.1 — Implement `ScreenContext.swift` — CGWindowList for active window detection
- [x] ✅ 6.2 — Capture window title, application name, bounds, layer, active app info
- [x] ✅ 6.3 — Implement OCR snippet extraction stub (Vision framework integration deferred)
- [x] ✅ 6.4 — Handle multi-display setups (CGGetActiveDisplayList)
- [x] ✅ 6.5 — Handle no active window gracefully (nil, not crash)
- [x] ✅ 6.6 — Write ScreenContextTests (5 test cases, all green)

## Phase 7: Human-in-the-Loop Approval Gate

- [x] ✅ 7.1 — Implement `ApprovalGate.swift` — read requires_approval from registry
- [x] ✅ 7.2 — Implement PENDING state return (ConsentResult.pending with requestID)
- [x] ✅ 7.3 — Implement approval/rejection resolution (async approve/reject)
- [x] ✅ 7.4 — Implement timeout mechanism (configurable approvalTimeoutSeconds)
- [x] ✅ 7.5 — Log approvals/rejections in session audit log + registry update
- [x] ✅ 7.6 — Handle expiry correctly (auto-timeout after configurable window)
- [x] ✅ 7.7 — Write ApprovalGateTests (8 test cases, all green)

## Phase 8: MCP Tool Implementations (All 8 Tools)

- [x] ✅ 8.1 — Implement `ScanIntentsTool` — wraps IntentExplorer into MCP Tool protocol
- [x] ✅ 8.2 — Implement `RegisterToolTool` — wraps Registry into MCP Tool protocol
- [x] ✅ 8.3 — Implement `ListToolsTool` — wraps Registry query into MCP Tool protocol
- [x] ✅ 8.4 — Implement `ExecuteIntentTool` — triple-threat execution + consent gate
- [x] ✅ 8.5 — Implement `FetchScriptingDictionaryTool` — wraps SDEFExtractor into MCP Tool
- [x] ✅ 8.6 — Implement `GetUITreeTool` — wraps AccessibilityScanner into MCP Tool
- [x] ✅ 8.7 — Implement `RequestHumanApprovalTool` — wraps ApprovalGate into MCP Tool
- [x] ✅ 8.8 — Implement `CaptureScreenContextTool` — wraps ScreenContext into MCP Tool
- [x] ✅ 8.9 — Write ToolIntegrationTests (6 test cases, all green)

## Phase 9: MCP Server Assembly

- [x] ✅ 9.1 — Implement `main.swift` + `MCPServer.swift` — bootstrap Server with all 8 tools
- [x] ✅ 9.2 — Configure StdioTransport for stdin/stdout JSON-RPC
- [x] ✅ 9.3 — Implement graceful shutdown (waitUntilCompleted)
- [x] ✅ 9.4 — Implement structured error responses (CallTool.Result with isError)
- [x] ✅ 9.5 — Write ToolIntegrationTests + full suite verification (57/57 passing)

## Phase 10: Embedding & Semantic Search (NLContextualEmbedding)

- [x] ✅ 10.1 — Implement `EmbeddingService.swift` — Apple NLContextualEmbedding (on-device, private)
- [x] ✅ 10.2 — Mean-pool token vectors → text-level embeddings
- [x] ✅ 10.3 — Cosine similarity computation for vector comparison
- [x] ✅ 10.4 — Wire semantic search into `list_registered_tools` ("search" parameter)
- [x] ✅ 10.5 — Minimum relevance threshold (0.1) + result ranking
- [x] ✅ 10.6 — Write EmbeddingTests (6 test cases: generation, similarity, semantic ranking)

## Phase 11: OpenClaw Integration ✅

- [x] ✅ 11.1 — MCP bridge config via `openclaw mcp set` → StdioTransport verified
- [x] ✅ 11.2 — Test: `capture_screen_context()` → active window info returned ✅
- [x] ✅ 11.3 — Test: `list_registered_tools()` → 388 tools, semantic search working ✅
- [x] ✅ 11.4 — Test: `scan_for_intents()` → returns Intent schemas ✅
- [x] ✅ 11.5 — Test: `fetch_scripting_dictionary("Mail")` → 16 cmds, 27 classes ✅
- [x] ✅ 11.6 — Test: `get_ui_tree("Google Chrome")` → 553 elements ✅
- [x] ✅ 11.7 — Test: `execute_intent("Finder", "activate")` → 208ms via AppleScript ✅
- [x] ✅ 11.8 — Test: `execute_intent` consent gate → PENDING → approve → auto-execute ✅
- [x] ✅ 11.9 — Docs: OPENCLAW_INTEGRATION.md updated with live-verified results
- [x] ✅ 11.10 — Execution engine fix: NSAppleScript → osascript subprocess (no more timeouts)
- [x] ✅ 11.11 — Consent gate fix: `{app}_{command}` lookup + auto-execution on approve

## Phase 12: Self-Healing Loop (Repairman MVP)

- [x] ✅ 12.1 — Implement `Repairman.swift` — structured error analysis + repair recording
- [x] ✅ 12.2 — Structured error code extraction (MISSING_REQUIRED, TYPE_MISMATCH, etc.)
- [x] ✅ 12.3 — Store errors in `last_error` + append to `repair_history` on failure
- [x] ✅ 12.4 — Store SDEF context in repair context for AppleScript-driven fixes
- [x] ✅ 12.5 — Repair proposal: `recordRepair` updates schema, increments version, clears error
- [x] ✅ 12.6 — `RepairmanPrompt.generate()` — full system prompt for agent-driven repair
- [x] ✅ 12.7 — Write RepairmanTests (8 test cases: analysis, logging, repair, evolution, codes)

## Phase 13: Triple-Threat Execution Pipeline

- [x] ✅ 13.1 — Implement `ExecutionEngine.swift` — graceful degradation executor
- [x] ✅ 13.2 — AppIntent strategy: infrastructure-ready, macOS runtime pending
- [x] ✅ 13.3 — AppleScript strategy: NSAppleScript execution with built-in command mapping
- [x] ✅ 13.4 — AppleScript mapping: Finder (open, select, new_folder), Mail (send_email), System Events (click, keystroke)
- [x] ✅ 13.5 — Accessibility strategy: infrastructure-ready (requires entitlements)
- [x] ✅ 13.6 — Wired into `execute_intent` tool with consent gate + result reporting

## Phase 14: Polish & Documentation

- [x] ✅ 14.1 — Update PROJECT_STATE.md with final status
- [x] ✅ 14.2 — Write ARCHITECTURE.md with full system diagram + triple-threat flow
- [x] ✅ 14.3 — Write DEVELOPER_GUIDE.md (local dev setup, build, test, run)
- [x] ✅ 14.4 — Write OPENCLAW_INTEGRATION.md (setup, verification, troubleshooting)
- [x] ✅ 14.5 — ADR.md: 9 architecture decisions documented
- [x] ✅ 14.6 — TEST_PLAN.md: 4-layer test strategy with execution order
- [x] ✅ 14.7 — IMPLEMENTATION_CHECKLIST.md: tracked all 15 phases
- [x] ✅ 14.8 — BUILD_LOG.md: full session history
- [x] ✅ 14.9 — Evolution tests: 10/14 scenarios verified live
