# MCP-x-Mac Seed — Evolution Guide

## What "Evolution" Means

Evolution is the recursive self-improvement loop. The Seed Server starts with primitive tools (scan, register, execute, repair). The AI agent (OpenClaw) uses these primitives to discover app capabilities, register new tools, execute them, and — when something fails — repair the tool schemas automatically. Each cycle makes the server more capable without any human code changes.

## The Evolution Loop

```
┌─────────────────────────────────────────────────────────────┐
│                    EVOLUTION CYCLE                          │
│                                                             │
│  1. DISCOVER    scan_for_intents("AppName")                 │
│       ↓         fetch_scripting_dictionary("AppName")      │
│  2. GROUND      Agent reads SDEF (source of truth)         │
│       ↓                                                     │
│  3. REGISTER    register_tool(name, app, schema)            │
│       ↓                                                     │
│  4. EXECUTE     execute_intent(app, intentName, params)     │
│       ↓                                                     │
│  5. REPAIR      ┌─ Success → tool stays active             │
│                 └─ Failure → Repairman analyzes            │
│                      → Agent references SDEF               │
│                      → Agent proposes fixed schema         │
│                      → register_tool (version++)            │
│                      → Retry execute                       │
│                                                             │
│  Circuit breaker: 3 failures → manual review flag          │
└─────────────────────────────────────────────────────────────┘
```

## What to Expect

### First Evolution (Next Session)
You'll ask OpenClaw to do something like "create a calendar event for tomorrow at 3pm." The agent will:

1. **Discover** — Call `scan_for_intents("Calendar")` to see what's available
2. **Ground** — Call `fetch_scripting_dictionary("Calendar")` to get exact commands
3. **Register** — Create a `calendar_create_event` tool with the right parameters
4. **Execute** — Run it — if Calendar's SDEF uses `make new event`, it works. If the agent guessed wrong, it fails.
5. **Repair** — On failure, the Repairman captures the error, feeds the SDEF back to the agent, and the agent corrects the schema. Version increments. Retry succeeds.

### Second Evolution
After a few cycles, your registry will have 20-30 custom tools that the agent created specifically for you — not auto-discovered, but *evolved* through real trial and error. These tools are versioned (v1 → v2 → v3) and their repair history shows every failure and fix.

### Third Evolution and Beyond
Once the agent has evolved tools for Calendar, Notes, Mail, Finder, and other daily apps, you can give compound commands like "find the invoice PDF from last week, email it to accounting, and create a reminder to follow up." The agent chains tools across apps because they're all in the same registry.

## How the Code Works

### The Registry (brain)
```
~/Library/Application Support/MCPxMacSeed/tools.db
```
Every tool is a row in SQLite with:
- `name`, `app`, `version`, `schema_json` — the tool definition
- `status` — active/broken/deprecated
- `requires_approval` — consent gate flag
- `last_error`, `repair_history` — failure tracking
- `created_at`, `updated_at` — timestamps

On upsert (same app+name), version increments and the schema updates. Old schemas are preserved in repair_history.

### The Triple-Threat Engine
When `execute_intent` is called:
1. **AppIntent** — Tries the Shortcuts CLI. If the app exposes its intent as a shortcut, it runs.
2. **AppleScript** — Falls back to `NSAppleScript`. Uses built-in command mapping for Finder, Mail, Reminders, and System Events. For other apps, constructs a generic `tell app...end tell` script from the parameters.
3. **Accessibility** — Last resort. Uses AXUIElement to find and click UI elements.

The strategy that worked is cached in `ExecutionResult.strategy`.

### The Repairman
On failure:
1. `analyzeFailure()` captures the error, current schema, and SDEF into a `RepairContext`
2. `RepairmanPrompt.generate()` produces a system prompt with the app's scripting dictionary
3. The agent reads the prompt, references the SDEF, and proposes a corrected schema
4. `recordRepair()` upserts the tool with the new schema — version increments, status goes to active

Circuit breaker caps repairs at 3 attempts per tool.

### The Trust Classifier
Every tool name is classified on registration:
- `get`, `read`, `open`, `check` → Tier 1 (safe, auto-execute)
- `delete`, `send`, `create`, `modify`, `execute` → Tier 2 (sensitive, consent-gated)

The consent gate pauses Tier 2 tools and returns a PENDING state. The human must explicitly approve.

### The Bootstrap
On first launch, `SystemBootstrap` scans every app in `/Applications` and `/System/Applications`:
- For each app, tries SDEF extraction → registers commands as tools
- Also discovers Shortcuts via `shortcuts list`
- Automatically classifies each tool into trust tiers
- Writes a `.bootstrap_complete` marker file so it only runs once

### Semantic Search
`list_registered_tools(search: "...")` uses a hybrid scoring:
- 70%: NLContextualEmbedding cosine similarity (Apple's on-device model)
- 30%: Keyword matching boost (if query words appear in tool name or app name)
- Exact tool name match gets maximum boost

This ensures "send a message" correctly ranks `mail_send` above unrelated tools.
