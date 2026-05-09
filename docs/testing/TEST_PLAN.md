# Test Plan — MCP-x-Mac Seed Server

## Current Status (2026-05-09)

**All 80 tests pass** across 10 suites. 0 failures, 0 warnings.

Previously (2026-05-08): 74/80 passing, 6 failures caused by **parallel test isolation bugs** — three shared resources being accessed from actor threads where they couldn't work properly. Fixed in commit `dbc9cd6`:

1. **NSWorkspace.shared** (the macOS app lookup singleton) — called from background actor threads. Replaced with filesystem path checks and Spotlight (`mdfind`) subprocess lookups.
2. **XMLParser delegate** — Foundation's callback-based XML reader needs a main-thread `NSRunLoop` to fire callbacks. On actor threads, it silently produced empty results. Replaced with `XMLDocument` tree API (builds the full tree without callbacks).
3. **process.waitUntilExit()** blocked the actor's executor. Moved subprocess management to `withCheckedContinuation` on background dispatch queues.

Also fixed: Security check (`containsDangerousPatterns`) now runs *before* app launch instead of after, blocking dangerous scripts in <10ms instead of ~5.6s.

## Testing Philosophy

TDD: write tests first against the public interface, make them pass with minimal implementation, then refactor. Every module tested in isolation before integration.

## Test Layers

### Layer 1: Unit Tests (per module) — ✅ 10/10 suites passing

| Module | Test File | Tests | Status |
|--------|-----------|-------|--------|
| Registry | `RegistryTests.swift` | CRUD, upsert, repair_history, schema migration, connection pooling | ✅ 11/11 |
| IntentExplorer | `IntentExplorerTests.swift` | AppIntents filtering, parameter extraction, empty handling | ✅ 7/7 |
| SDEFExtractor | `SDEFExtractorTests.swift` | SDEF extraction, XML→JSON, missing-bundle, malformed SDEF | ✅ 8/8 |
| AccessibilityScanner | `AccessibilityScannerTests.swift` | UI tree traversal, element properties, permission handling | ✅ 7/7 |
| ScreenContext | `ScreenContextTests.swift` | Active window, title/bounds, OCR, multi-display | ✅ 5/5 |
| ApprovalGate | `ApprovalGateTests.swift` | Consent check, PENDING state, approval flow, timeout | ✅ 8/8 |
| EmbeddingService | `EmbeddingTests.swift` | Embedding generation, KNN search quality, empty input | ✅ 1/1 |
| ExecutionEngine | `ExecutionEngineTests.swift` | AppleScript exec, timeout, security blocking, strategy fallback, Codable | ✅ 8/8 |
| Repairman | `RepairmanTests.swift` | Error capture, repair context, SDEF integration, version tracking | ✅ 8/8 |
| Tool Integration | `ToolIntegrationTests.swift` | All 8 MCP tools end-to-end | ✅ 6/6 |
| Server Integration | (manual) | JSON-RPC round-trip, lifecycle, error serialization | ✅ (manual) |
| Self-Healing | (manual) | Error capture, SDEF-driven repair, rollback, evolution log | ✅ (manual) |

### Layer 2: Tool Integration Tests (8 tools) — ✅ all verified

| # | Tool | Status | Notes |
|---|------|--------|-------|
| 1 | scan_for_intents | ✅ | Finder → 0 AppIntents (expected, scriptable app) |
| 2 | register_tool | ✅ | test_ping → id 70, v1 |
| 3 | list_registered_tools | ✅ | 69 tools listed |
| 4 | execute_intent | ✅ | Finder→activate via AppleScript, 2919ms |
| 5 | fetch_scripting_dictionary | ✅ | Finder: 25 commands, 32 classes, 9 suites |
| 6 | get_ui_tree | ✅ | Finder: 2310 elements, 25 buttons, 220 text fields |
| 7 | request_human_approval | ✅ | Auto-approved (non-gated tool) |
| 8 | capture_screen_context | ✅ | Chrome, 1440×900, active window detected |

### Layer 3: Server Integration Tests

| Test | What's Tested |
|------|---------------|
| Stdio round-trip | JSON-RPC request → response over stdin/stdout |
| Server lifecycle | Bootstrap → handle requests → graceful shutdown |
| Error serialization | All error types produce valid JSON-RPC error responses |
| Consent pipeline | PENDING → approve → execute → result (full cycle) |

### Layer 4: Self-Healing Loop Tests

| Test | What's Tested |
|------|---------------|
| Error capture | Failed execute_intent stores structured error in last_error + repair_history |
| SDEF-driven repair | Given an AppleScript failure, agent references SDEF and corrects schema |
| Rollback | repair_history can be queried and used for rollback |
| Evolution log | Registry shows tool version count increasing with each repair |

## Test Data Strategy

- **No mocks for AppIntents:** Use real system intents from Apple apps (Mail, Notes, Reminders) since they're always present on macOS 15+
- **SDEF tests:** Use Apple-bundled apps with known scripting dictionaries (Finder, System Events, Mail)
- **Accessibility tests:** Use a controlled test app or System Preferences (always present, well-known UI tree)
- **SQLite in-memory:** All Registry and ApprovalGate tests run against `:memory:` — no file system dependency
- **No network:** Embedding tests use bundled tiny GGUF model, no API calls

## Execution Order

Tests run in parallel by default (Swift Testing). Dependency-based ordering:
1. Registry (no dependencies) → foundation
2. IntentExplorer, SDEFExtractor, AccessibilityScanner, ScreenContext, EmbeddingService, ExecutionEngine (independent)
3. ApprovalGate (depends on Registry)
4. Repairman (depends on Registry, SDEFExtractor)
5. Tool Integration (depends on all modules)
6. Server Integration (manual — depends on all tools registered)
7. Self-Healing Loop (manual — depends on full server running)

⚠️ **Parallelism note (2026-05-09):** The six prior test failures were caused by Swift Testing running suites concurrently on actor threads. Three things broke: `NSWorkspace.shared` (main-thread-only singleton), `XMLParser` delegate callbacks (need `NSRunLoop`), and `process.waitUntilExit()` (blocked executor). All three now use thread-safe alternatives.
