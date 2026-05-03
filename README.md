# MCP-x-Mac Seed

**A self-evolving MCP server that gives AI agents the ability to control any macOS application — including the ones without APIs.**

No hardcoded integrations. No per-app plugins. The agent discovers capabilities itself, writes its own tools, and repairs them when apps update.

```
388 tools auto-discovered across ~50 apps in 2 seconds on first run.
```

[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-orange)](https://swift.org)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)](https://apple.com/macos)
[![Tests](https://img.shields.io/badge/tests-80%2F80-green)](#)
[![License](https://img.shields.io/badge/license-MIT-brightgreen)](LICENSE)

## What It Does

Give an AI agent these 8 primitive tools, and it builds everything else:

```
┌──────────────────────┐     stdio/JSON-RPC      ┌───────────────────────────┐
│    AI Agent          │ ◄─────────────────────► │    MCP-x-Mac Seed Server   │
│  (OpenClaw, Claude,  │                         │     (Swift 6.3 binary)     │
│   Cursor, Copilot)   │                         └─────────────┬─────────────┘
└──────────────────────┘                                       │
                    ┌──────────────────────────────────────────┼──────────────────────┐
                    │                                          │                      │
            ┌───────▼────────┐                    ┌───────────▼────────┐   ┌─────────▼──────────┐
            │  SQLite + NL   │                    │  Triple-Threat     │   │   Screen Context    │
            │  Embeddings    │                    │  Execution Engine  │   │   (CGWindowList)    │
            │  (Registry)    │                    │                    │   │                     │
            └───────┬────────┘                    └─────────┬──────────┘   └─────────────────────┘
                    │                                      │
    ┌───────────────┼───────────────┐         ┌────────────┼───────────────┐
    │               │               │         │            │               │
┌───▼────┐  ┌──────▼──────┐  ┌────▼─────┐ ┌─▼──────────┐ ┌▼──────────┐ ┌─▼──────────────┐
│ Tools  │  │ Repair      │  │ Semantic │ │ AppIntents  │ │ AppleScript│ │ Accessibility  │
│ Table  │  │ History     │  │ Search   │ │ Explorer    │ │ SDEF Parser│ │ Scanner        │
└────────┘  └─────────────┘  └──────────┘ └────────────┘ └────────────┘ └────────────────┘
```

### The Recursive Meta-Compiler Pattern

1. **Discover** — Agent scans apps for capabilities (AppIntents, SDEF, Accessibility)
2. **Refine** — Agent analyzes raw schemas against the app's own documentation
3. **Register** — Clean, typed tools stored in SQLite with versioning
4. **Execute** — Triple-threat: AppIntents → AppleScript → Accessibility
5. **Repair** — Failures trigger the Repairman loop; agent fixes its own tools

### Triple-Threat Execution

Every command tries three strategies in order:

| Tier | Strategy | What It Works On |
|------|----------|-----------------|
| 1 | **AppIntents** | Modern apps with Siri/Shortcuts support |
| 2 | **AppleScript (SDEF)** | Professional Mac apps, legacy software |
| 3 | **Accessibility API** | Electron apps, Java apps, anything with a UI |

### Self-Healing

When a tool fails, the Repairman captures the error context — including the app's scripting dictionary — and generates a structured prompt teaching the agent how to fix it. Circuit breaker prevents repair loops (max 3 attempts).

## Quick Start

```bash
# Clone and build
git clone https://github.com/YOUR_USER/mcp-x-mac-seed.git
cd mcp-x-mac-seed
swift build

# Register with your MCP client (example: OpenClaw)
openclaw mcp set mcp-x-mac-seed \
  '{"command":"'$(pwd)'/.build/arm64-apple-macosx/debug/MCPxMacSeed","args":[]}'
openclaw gateway restart

# Also works with Claude Desktop, Cursor, VS Code, any MCP client
```

On first run, the server auto-discovers every app on your Mac:

```
[Bootstrap] First run — scanning all apps for capabilities...
[Bootstrap] Done. 388 tools auto-discovered.
```

## The 8 Seed Tools

| # | Tool | Description |
|---|------|-------------|
| 1 | `scan_for_intents` | Discover AppIntents for any app |
| 2 | `register_tool` | Save refined tool schemas to the persistent registry |
| 3 | `list_registered_tools` | Query tools (exact match or semantic search) |
| 4 | `execute_intent` | Triple-threat execution with consent gating |
| 5 | `fetch_scripting_dictionary` | Extract full AppleScript dictionary from any app |
| 6 | `get_ui_tree` | Accessibility API fallback — scan any app's UI elements |
| 7 | `request_human_approval` | Human-in-the-loop consent for destructive operations |
| 8 | `capture_screen_context` | Active window, app, display config (gives the agent "eyes") |

## Safety

- **Consent gating** — destructive operations (send, delete, format) pause for human approval
- **Security filter** — AppleScript is scanned for dangerous patterns before execution
- **Audit trail** — every approval/rejection is logged
- **Circuit breaker** — max 3 repair attempts per tool
- **No network exposure** — stdio transport, no open ports
- **On-device embeddings** — semantic search uses Apple's NLContextualEmbedding, zero data leaves the machine

## Requirements

- macOS 15+ (Sequoia or later)
- Swift 6.3 toolchain (Xcode 16+)
- For Accessibility scanning: grant Accessibility permission in System Settings
- For AppleScript automation: grant Automation permission for target apps

## Architecture

```
Sources/MCPxMacSeed/
├── main.swift                  # Entry point
├── MCPServer.swift             # MCP Server bootstrap + StdioTransport
├── Database/
│   ├── Registry.swift          # SQLite-backed tool store (GRDB.swift)
│   ├── Models.swift            # ToolRecord, RepairEntry, ApprovalRecord
│   └── EmbeddingService.swift  # NLContextualEmbedding semantic search
├── AppIntents/
│   ├── IntentExplorer.swift    # AppIntents discovery (Info.plist, AssistantSchemas)
│   ├── SDEFExtractor.swift     # AppleScript dictionary parser (XML → structured)
│   ├── AccessibilityScanner.swift # AXUIElement UI tree traversal
│   ├── ScreenContext.swift     # CGWindowList active window + display capture
│   ├── ApprovalGate.swift      # HITL consent pipeline with timeouts
│   ├── ExecutionEngine.swift   # Triple-threat execution (AppIntent→AS→AX)
│   ├── Repairman.swift         # Self-healing loop with circuit breaker
│   ├── SystemBootstrap.swift   # Auto-discovery on first run
│   └── TrustClassifier.swift   # Pattern-based action classification
└── Tools/
    └── ToolRegistrations.swift  # All 8 MCP tool handlers + JSON schema builders
```

## MCP Client Compatibility

Works with any MCP-compatible client:

- **OpenClaw** — native stdio transport
- **Claude Desktop** — add to `claude_desktop_config.json`
- **Cursor** — add to `.cursor/mcp.json`
- **VS Code** — GitHub Copilot, Continue.dev, Cline
- **Any MCP client** — standard JSON-RPC over stdio

## License

MIT — see [LICENSE](LICENSE) for details.

---

*Built with the recursive meta-compiler pattern: agents that write their own tools, repair themselves, and never hit a dead end.*
