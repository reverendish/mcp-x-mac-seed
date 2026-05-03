# Test Plan — MCP-x-Mac Seed Server

## Testing Philosophy

TDD: write tests first against the public interface, make them pass with minimal implementation, then refactor. Every module tested in isolation before integration.

## Test Layers

### Layer 1: Unit Tests (per module)

| Module | Test File | What's Tested |
|--------|-----------|---------------|
| Registry | `RegistryTests.swift` | CRUD, upsert conflict, repair_history append/retrieval, schema migration, connection pooling |
| IntentExplorer | `IntentExplorerTests.swift` | AppIntents.all filtering, parameter extraction, missing-app handling, empty-intent handling |
| SDEFExtractor | `SDEFExtractorTests.swift` | .sdef extraction from app bundles, XML→JSON conversion, missing-bundle handling, malformed SDEF |
| AccessibilityScanner | `AccessibilityScannerTests.swift` | UI element tree traversal, element property extraction, permission-denied handling |
| ScreenContext | `ScreenContextTests.swift` | Active window detection, title/bounds capture, OCR snippet extraction |
| ApprovalGate | `ApprovalGateTests.swift` | Consent check for gated tools, PENDING state return, approval → execution flow |
| EmbeddingService | `EmbeddingTests.swift` | Local embedding generation, KNN search quality, empty/null input handling |

### Layer 2: Tool Integration Tests (8 tools)

| # | Tool | Test File | What's Tested |
|---|------|-----------|---------------|
| 1 | scan_for_intents | `ToolIntegrationTests.swift` | Returns valid JSON schema, handles unknown app, empty intents |
| 2 | register_tool | `ToolIntegrationTests.swift` | Creates tool, rejects duplicate, validates schema shape |
| 3 | list_registered_tools | `ToolIntegrationTests.swift` | Exact app filter, semantic search, empty results |
| 4 | execute_intent | `ToolIntegrationTests.swift` | Successful execution, parameter validation, structured error capture, consent gate interaction |
| 5 | fetch_scripting_dictionary | `ToolIntegrationTests.swift` | SDEF extraction, XML→JSON, search_dictionary sub-tool |
| 6 | get_ui_tree | `ToolIntegrationTests.swift` | UI tree traversal, element property extraction, fallback flow |
| 7 | request_human_approval | `ToolIntegrationTests.swift` | PENDING state, approval flow, timeout handling |
| 8 | capture_screen_context | `ToolIntegrationTests.swift` | Active window detection, OCR snippet, multi-display |

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

Tests are run in dependency order:
1. Registry (no dependencies) → foundation for everything
2. IntentExplorer, SDEFExtractor, AccessibilityScanner, ScreenContext (independent unit tests)
3. EmbeddingService (depends on Registry for vec0 table)
4. ApprovalGate (depends on Registry for requires_approval flag)
5. Tool Integration (depends on all modules)
6. Server Integration (depends on all tools registered)
7. Self-Healing Loop (depends on full server running)
