# MCP-x-Mac Seed — OpenClaw Integration Guide

**Status:** ✅ Verified working — 2026-05-03
**Server version:** 0.1.0
**Registry:** 388 tools across ~50 apps

## Quick Start

```bash
# 1. Clone and build
cd ~/Desktop/mcp-x-mac-seed
swift build

# 2. Register as an MCP server
openclaw mcp set mcp-x-mac-seed \
  '{"command":"/Users/ishsitotombe/Desktop/mcp-x-mac-seed/.build/arm64-apple-macosx/debug/MCPxMacSeed","args":[]}'

# 3. Restart the gateway
openclaw gateway restart

# 4. Verify tools are available
openclaw mcp list
```

## Live-Verified Tools

All 8 seed tools tested and confirmed working via OpenClaw MCP bridge:

| # | Tool | Status | Notes |
|---|------|--------|-------|
| 1 | `scan_for_intents` | ✅ | Returns AppIntent schemas from app bundles |
| 2 | `register_tool` | ✅ | Writes to SQLite registry with versioning |
| 3 | `list_registered_tools` | ✅ | 388 tools registered, semantic search working |
| 4 | `execute_intent` | ✅ | AppleScript via osascript, 200-1000ms |
| 5 | `fetch_scripting_dictionary` | ✅ | SDEF extraction works (Mail: 16 cmds, 27 classes) |
| 6 | `get_ui_tree` | ✅ | Accessibility tree (Chrome: 553 elements) |
| 7 | `request_human_approval` | ✅ | Consent gate + auto-execution on approve |
| 8 | `capture_screen_context` | ✅ | Active window, app, display config |

## What Happens on First Run

The server auto-discovers all apps on your Mac and registers their commands as MCP tools:

```
[Bootstrap] First run — scanning all apps for capabilities...
[Bootstrap] Done. 388 tools auto-discovered.
```

Registry: `~/Library/Application Support/MCPxMacSeed/tools.db`

## Architecture

```
OpenClaw Gateway ──[stdio/JSON-RPC]──► MCPxMacSeed binary
                                          │
                          ┌───────────────┼───────────────┐
                          │               │               │
                     SQLite Registry   Execution Engine   Screen Context
                     (388 tools)      (AppIntent→AS→AX)  (CGWindowList)
```

The server uses `StdioTransport` — OpenClaw spawns it as a child process and communicates over stdin/stdout JSON-RPC. No ports, no TLS, no network exposure.

## Config File

```json
// ~/.openclaw/openclaw.json → mcp.servers.mcp-x-mac-seed
{
  "command": "/Users/ishsitotombe/Desktop/mcp-x-mac-seed/.build/arm64-apple-macosx/debug/MCPxMacSeed",
  "args": []
}
```

## Troubleshooting

**execute_intent times out:**
- Fixed in v0.1.1 — replaced blocking NSAppleScript with osascript subprocess + timeout
- Rebuild: `swift build && openclaw gateway restart`

**Sensitive commands crash with RegistryError:**
- Fixed in v0.1.1 — consent gate now uses `{app}_{command}` lookup fallback
- Unregistered tools skip consent gating and rely on ExecutionEngine security filter

**Tools not showing up after rebuild:**
- `openclaw gateway restart` — the old binary is cached until restart

**"Damaged app" errors during bootstrap:**
- Problematic apps (Automator Stub, etc.) are automatically skipped
- Bootstrap continues scanning other apps

**Accessibility permissions:**
- `get_ui_tree` requires Accessibility permission
- Grant in System Settings → Privacy & Security → Accessibility
