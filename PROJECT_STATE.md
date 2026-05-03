# MCP-x-Mac Seed Server — Project State

**Status:** Pre-implementation — strategic pivot integrated, planning complete
**Last Updated:** 2026-05-03
**Architecture:** Recursive meta-compiler with triple-threat execution engine

## Project Summary

A Swift 6.3 MCP server that provides OpenClaw with a self-evolving bridge to macOS. The Seed Server starts with zero tools and discovers, wraps, and repairs its own capabilities through an agentic loop. It spans three generations of macOS control: App Intents (modern), AppleScript via SDEF (legacy/pro), and Accessibility API (brute-force fallback). Safety is enforced through a consent-gating system for destructive operations.

## Current Phase

📋 Planning complete — 8 tools defined across triple-threat architecture, ready to begin Phase 2 (Registry)

## The Three Pillars

### Pillar 1: Recursive Meta-Compiler (Seed & Evolution)
- Agent uses `scan_for_intents` to discover app capabilities
- Agent refines raw metadata into clean MCP tool schemas (itself the Wrapper/Repairman)
- SQLite + sqlite-vec registry stores all tools with versioning, repair history, and semantic search
- Self-healing: failures → error capture → schema adjustment → retry

### Pillar 2: Triple-Threat Execution Engine
- **App Intents** (Tier 1): Type-safe, native API calls via AssistantSchemas
- **AppleScript SDEF** (Tier 2): Legacy/Pro apps via dictionary-driven synthesis — agent reads official .sdef docs before writing code
- **Accessibility API** (Tier 3): Brute-force fallback via UI element tree for apps with no API

### Pillar 3: Onscreen Awareness & Safety
- **Screen context:** `capture_screen_context` gives the agent "eyes" on your current task
- **HITL consent:** `request_human_approval` gates destructive operations behind native macOS notification + explicit approval
- **Semantic routing:** Domain-level tool grouping (manage_finance, manage_media) to prevent context window bloat

## The 8 Tools

| # | Tool | Pillar | Purpose |
|---|------|--------|---------|
| 1 | `scan_for_intents` | 1 | Discover AppIntents for any app |
| 2 | `register_tool` | 1 | Write refined tool definitions into registry |
| 3 | `list_registered_tools` | 1 | Query registry (exact + semantic search) |
| 4 | `execute_intent` | 2 | Execute AppIntent or AppleScript with structured error capture |
| 5 | `fetch_scripting_dictionary` | 2 | Extract .sdef from app bundle as structured schema |
| 6 | `get_ui_tree` | 2 | Accessibility API fallback — scan UI element tree |
| 7 | `request_human_approval` | 3 | Consent gate for destructive operations |
| 8 | `capture_screen_context` | 3 | Active window title, bounds, OCR snippet |

## Quick Links

- [Implementation Checklist](/Users/ishsitotombe/Desktop/mcp-x-mac-seed/docs/checklists/IMPLEMENTATION_CHECKLIST.md)
- [Architecture Decision Records](/Users/ishsitotombe/Desktop/mcp-x-mac-seed/docs/architecture/ADR.md)
- [Test Plan](/Users/ishsitotombe/Desktop/mcp-x-mac-seed/docs/testing/TEST_PLAN.md)
- [Logs](/Users/ishsitotombe/Desktop/mcp-x-mac-seed/docs/logs/)
