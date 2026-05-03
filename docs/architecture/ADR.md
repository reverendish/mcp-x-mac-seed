# Architecture Decision Records — MCP-x-Mac Seed Server

## ADR-001: SQLite + sqlite-vec over Standalone Vector DB

**Date:** 2026-05-03
**Status:** Accepted

**Context:** The tool registry needs both relational (schema, status, repair history) and semantic (search by description) capabilities.

**Decision:** Use SQLite with the `sqlite-vec` extension rather than running a separate vector database.

**Rationale:**
- ACID transactions across relational + vector writes (atomic tool registration)
- Zero network overhead (local execution only, consistent with privacy goals)
- Single file deployment (no service orchestration)
- `sqlite-vec` is pure C, no dependencies, runs on macOS trivially

**Alternatives considered:**
- Qdrant/Milvus: Dual-database architecture, eventual consistency problems, additional service dependency
- Chroma: Python-native, adds runtime dependency outside Swift ecosystem
- PostgreSQL + pgvector: Overkill for a local single-user tool registry

---

## ADR-002: sqlite-lembed for Local Embeddings

**Date:** 2026-05-03
**Status:** Accepted

**Context:** Semantic tool search needs text embeddings. Options: remote API (OpenAI), local server (Ollama), or in-process (sqlite-lembed).

**Decision:** Use `sqlite-lembed` with a bundled tiny GGUF model for in-process embedding generation.

**Rationale:**
- Zero network calls (privacy, no API keys, no latency)
- Same SQLite extension ecosystem as sqlite-vec (consistency)
- The search space is small (hundreds of tools, not millions) — a tiny embedding model is sufficient
- Solves the "no internet → no semantic search" failure mode

**Alternatives considered:**
- OpenAI embeddings API: Requires API key, network latency, cost at scale
- Ollama: Requires separate service, adds deployment complexity
- Apple's NaturalLanguage framework: Could work for text → embedding but is opaque and not SQL-native

---

## ADR-003: GRDB.swift over Raw SQLite C API

**Date:** 2026-05-03
**Status:** Accepted

**Context:** SQLite access from Swift. Options: raw sqlite3 C API, GRDB.swift, or FMDB.

**Decision:** Use GRDB.swift for all SQLite operations.

**Rationale:**
- Swift-native async/await support (no callback hell)
- Type-safe query building (catches schema errors at compile time)
- Built-in migration system (schema versioning out of the box)
- Active maintenance, widely used in production Swift apps

**Alternatives considered:**
- Raw sqlite3 C API: Manual memory management, error-prone, no async/await
- FMDB: Objective-C bridge, no async/await, less idiomatic in Swift 6

---

## ADR-004: StdioTransport over HTTP for MCP

**Date:** 2026-05-03
**Status:** Accepted

**Context:** MCP supports both stdio (subprocess) and HTTP (Streamable) transports.

**Decision:** Use `StdioTransport` exclusively.

**Rationale:**
- Lowest latency (no network stack, direct pipe)
- No port conflicts, no TLS, no auth
- Matches the "local tool" model — the seed server is a child process of OpenClaw
- Zero attack surface (no open ports)

**Alternatives considered:**
- HTTP/SSE transport: Adds latency, requires port management, unnecessary for local-only use

---

## ADR-005: OpenClaw as Wrapper/Repairman (Not Built into Swift)

**Date:** 2026-05-03
**Status:** Accepted

**Context:** Tier 2 (Wrapper) and Tier 3 (Repairman) need LLM intelligence to refine raw AppIntents metadata and repair broken schemas.

**Decision:** Do not embed an LLM in the Swift server. Expose DB access to OpenClaw and let the agent perform schema refinement and repair.

**Rationale:**
- OpenClaw already has model access and reasoning capability
- Embedding an LLM in Swift adds massive binary size, model management complexity, and Swift/ML boundary friction
- The Seed Server is the primitive layer; OpenClaw is the compiler
- Keeps the Swift binary small, fast, and single-purpose

**Alternatives considered:**
- Bundle Llama 3.4 via MLX Swift: Complex, bloated binary, redundant with OpenClaw's model access
- Remote LLM API from Swift: Adds network dependency, breaks the "everything local" principle

---

## ADR-006: AppleScript Support via SDEF Reference (Not Training Data)

**Date:** 2026-05-03
**Status:** Accepted

**Context:** Many professional Mac apps (Adobe CC, OmniFocus, ProTools) have deep AppleScript support but shallow or no AppIntents. The agent needs to control these apps, but writing AppleScript from LLM training data produces hallucinated commands for specific app versions.

**Decision:** Implement a `fetch_scripting_dictionary` tool that extracts the `.sdef` XML from an app's bundle, converts it to structured JSON/Markdown, and feeds it to the agent as reference context. The agent must reference the SDEF before writing any AppleScript.

**Rationale:**
- SDEF files are the literal source of truth — the same metadata macOS uses to parse AppleScript commands
- Eliminates the "hallucination vs. versioning" gap — agent sees exact commands for the installed version
- Self-updating: app updates → new SDEF → agent discovers new commands instantly
- Reduces token waste: send only the app-specific dictionary, not the entire AppleScript Language Guide
- For massive dictionaries (Outlook, Excel), pair with `search_dictionary` using sqlite-vec for targeted command lookup

**Alternatives considered:**
- Let agent write AppleScript from training data: High hallucination rate, especially for version-specific APIs
- Manually curate AppleScript docs per app: Doesn't scale, rots on app updates
- Skip AppleScript entirely, rely on Accessibility fallback: Loses the precision and speed of scripted automation

---

## ADR-007: Accessibility API as Execution Fallback (AXorcist Pattern)

**Date:** 2026-05-03
**Status:** Accepted

**Context:** Electron apps, Java apps, and other non-native applications expose neither AppIntents nor AppleScript. Without a fallback, these apps are completely uncontrollable by the agent.

**Decision:** Implement a `get_ui_tree` tool that uses the macOS Accessibility API (AXUIElement) to scan the UI element tree of any application, returning a structured representation of buttons, text fields, menus, and their properties.

**Rationale:**
- Covers the "dark" app ecosystem (Electron, Java, legacy Carbon)
- Provides graceful degradation: AppIntent → AppleScript → Accessibility → fail with clear error
- AXUIElement API is C-based and callable from Swift directly (no external dependencies)
- 2026 community standard: the "AXorcist" pattern is proven in open-source automation tools

**Alternatives considered:**
- Screenshot + vision model: Higher latency, more expensive, less reliable for precise UI interaction
- Accept that some apps can't be automated: Violates the "never hit a dead end" principle

---

## ADR-008: Human-in-the-Loop Consent Gating

**Date:** 2026-05-03
**Status:** Accepted

**Context:** As agent autonomy increases, the blast radius of a hallucinated destructive action (delete email, empty trash, send payment) becomes unacceptable. Pure "trust the agent" is not viable for production use.

**Decision:** Implement a `requires_approval` flag in the tool registry. For gated tools, `execute_intent` returns a PENDING state with the full proposed action payload. A separate `request_human_approval` tool delivers a native macOS notification and waits for explicit approval before execution continues.

**Rationale:**
- Safety without crippling utility — most actions auto-execute, only destructive ones gate
- Approval recording creates an audit trail (stored in registry alongside repair_history)
- Matches the macOS security model (TCC prompts) — users already expect "this app wants to..." dialogs
- Native notification ensures approval is visible even when OpenClaw is backgrounded

**Alternatives considered:**
- No gating: Unacceptable blast radius for production use
- Gate everything: Cripples utility, user fatigue from constant approvals
- Confirmation in chat: Not visible if chat surface is not active

---

## ADR-009: Screen Context Awareness via Quartz Window Server

**Date:** 2026-05-03
**Status:** Accepted

**Context:** The agent is blind to what the user is currently doing. Commands like "fill out this form" or "send this" require the agent to know which window is active and what content is on screen.

**Decision:** Implement `capture_screen_context` that uses Quartz Window Server (CGWindowList) to get the active window's title, application, bounds, and optionally an OCR-processed snippet of its content.

**Rationale:**
- Transforms agent from blind script-runner to contextual collaborator
- Enables "this" references — "send this," "fill this out," "reply to this"
- CGWindowList is a public C API, callable from Swift without entitlements for basic info
- OCR via Apple's Vision framework is on-device, private, and fast on Apple Silicon

**Alternatives considered:**
- Require user to explicitly name the target each time: Breaks natural language flow, worse UX
- Screenshot everything: Privacy concern, high storage cost, token waste
