# MCP-x-Mac Seed Server — Architecture

## Overview

The MCP-x-Mac Seed Server is a self-evolving bridge between OpenClaw and macOS. It implements a **recursive meta-compiler** pattern: instead of hardcoding tools for every app, the server provides discovery primitives and lets the AI agent (OpenClaw) discover, wrap, and repair its own tools.

## System Architecture

```
┌──────────────────────┐     stdio/JSON-RPC      ┌───────────────────────────┐
│      OpenClaw        │ ◄─────────────────────► │    MCP-x-Mac Seed Server   │
│   (Wrapper/Repairman) │                         │     (Swift 6.3 binary)     │
└──────────────────────┘                         └─────────────┬─────────────┘
                                                               │
                    ┌──────────────────────────────────────────┼──────────────────────┐
                    │                                          │                      │
            ┌───────▼────────┐                    ┌───────────▼────────┐   ┌─────────▼──────────┐
            │  SQLite + NL   │                    │  Triple-Threat     │   │   MCP.swift SDK    │
            │  Embeddings    │                    │  Execution Engine  │   │   (0.12.0)         │
            │  (Registry)    │                    │                    │   │                    │
            └───────┬────────┘                    └─────────┬──────────┘   └────────────────────┘
                    │                                      │
    ┌───────────────┼───────────────┐         ┌────────────┼───────────────┐
    │               │               │         │            │               │
┌───▼────┐  ┌──────▼──────┐  ┌────▼─────┐ ┌─▼──────────┐ ┌▼──────────┐ ┌─▼──────────────┐
│ Tools  │  │ Repair      │  │ Semantic │ │ AppIntents  │ │ AppleScript│ │ Accessibility  │
│ Table  │  │ History     │  │ Search   │ │ Explorer    │ │ SDEF Parser│ │ Scanner        │
└────────┘  └─────────────┘  └──────────┘ └────────────┘ └────────────┘ └────────────────┘
```

## The Three Pillars

### Pillar 1: Recursive Meta-Compiler
The server starts with 8 seed tools. OpenClaw uses these to discover app capabilities, refine schemas, and register new tools in the SQLite registry. Each failure feeds into the Repairman loop, which captures the error, references the app's SDEF (for AppleScript), and produces a corrected schema.

### Pillar 2: Triple-Threat Execution Engine
Every `execute_intent` call tries three strategies in order:
1. **AppIntents** — Type-safe native API calls (infrastructure ready, macOS runtime pending)
2. **AppleScript** — SDEF-verified AppleScript commands with built-in command mapping for Finder, Mail, System Events
3. **Accessibility API** — AXUIElement brute-force fallback (requires accessibility permissions)

### Pillar 3: Safety & Awareness
- **Consent gate:** Tools marked `requires_approval` pause execution and require explicit human approval
- **Screen context:** `capture_screen_context` gives the agent "eyes" on your active app/window
- **Audit trail:** Every approval/rejection and repair attempt is logged in the registry

## Module Map

| Module | File | Responsibility |
|--------|------|---------------|
| Registry | `Database/Registry.swift` | SQLite-backed tool store with versioning and repair history |
| Models | `Database/Models.swift` | ToolRecord, RepairEntry, ApprovalRecord, error types |
| Embeddings | `Database/EmbeddingService.swift` | NLContextualEmbedding — semantic search over tool descriptions |
| IntentExplorer | `AppIntents/IntentExplorer.swift` | AppIntents discovery via Info.plist + AssistantSchemas |
| SDEFExtractor | `AppIntents/SDEFExtractor.swift` | AppleScript SDEF extraction and parsing |
| AccessibilityScanner | `AppIntents/AccessibilityScanner.swift` | AXUIElement UI tree traversal |
| ScreenContext | `AppIntents/ScreenContext.swift` | CGWindowList active window + display info |
| ApprovalGate | `AppIntents/ApprovalGate.swift` | HITL consent pipeline with timeout |
| ExecutionEngine | `AppIntents/ExecutionEngine.swift` | Triple-threat execution (AppIntent → AppleScript → AX) |
| Repairman | `AppIntents/Repairman.swift` | Failure analysis, repair recording, prompt generation |
| ToolRegistry | `Tools/ToolRegistrations.swift` | MCP tool definitions + handlers for all 8 tools |
| Server | `MCPServer.swift` | MCP Server bootstrap + stdio transport |

## The 8 Tools

| # | Tool | Category | Reads/Writes |
|---|------|----------|-------------|
| 1 | `scan_for_intents` | Discovery | Read |
| 2 | `register_tool` | Registry | Write |
| 3 | `list_registered_tools` | Registry | Read (with semantic search) |
| 4 | `execute_intent` | Execution | Write (with consent gate) |
| 5 | `fetch_scripting_dictionary` | SDEF | Read |
| 6 | `get_ui_tree` | Accessibility | Read |
| 7 | `request_human_approval` | Safety | Read/Write |
| 8 | `capture_screen_context` | Awareness | Read |

## Self-Healing Loop

```
Failure → Repairman.analyzeFailure()
         → RepairContext (error code, schema, SDEF, history)
         → RepairmanPrompt.generate()
         → Agent (OpenClaw) diagnoses + proposes fix
         → Repairman.recordRepair(newSchema, success: true)
         → Registry: version++, status→active, error→nil
```

## Technology Stack

- **Language:** Swift 6.3
- **MCP SDK:** modelcontextprotocol/swift-sdk 0.12.0
- **Database:** GRDB.swift 7.10.0 (SQLite)
- **Embeddings:** Apple NLContextualEmbedding (on-device, private)
- **Transport:** StdioTransport
- **Platform:** macOS 15+ (tested on macOS 26)
