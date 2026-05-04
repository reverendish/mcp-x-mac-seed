# MCP-x-Mac-Seed — Developer Guide

## Prerequisites

- macOS 15+ (Sequoia or later)
- Xcode 16+ (tested on Xcode 26.4)
- Swift 6.3 toolchain

## Setup

```bash
cd ~/Desktop/mcp-x-mac-seed
swift build
swift test
```

## Project Structure

```
mcp-x-mac-seed/
├── Package.swift                          # Swift Package Manager config
├── Sources/MCPxMacSeed/
│   ├── main.swift                         # Entry point
│   ├── MCPServer.swift                    # MCP Server bootstrap
│   ├── Database/
│   │   ├── Registry.swift                 # SQLite tool registry
│   │   ├── Models.swift                   # Data models
│   │   └── EmbeddingService.swift         # Semantic search (NLContextualEmbedding)
│   ├── AppIntents/
│   │   ├── IntentExplorer.swift           # AppIntents discovery
│   │   ├── SDEFExtractor.swift            # AppleScript SDEF parser
│   │   ├── AccessibilityScanner.swift     # AXUIElement tree scanner
│   │   ├── ScreenContext.swift            # Active window + display capture
│   │   ├── ApprovalGate.swift             # HITL consent pipeline
│   │   ├── ExecutionEngine.swift          # Triple-threat execution
│   │   └── Repairman.swift                # Self-healing loop
│   └── Tools/
│       └── ToolRegistrations.swift        # All 8 MCP tool handlers
├── Tests/MCPxMacSeedTests/
│   ├── RegistryTests.swift
│   ├── IntentExplorerTests.swift
│   ├── SDEFExtractorTests.swift
│   ├── AccessibilityScannerTests.swift
│   ├── ScreenContextTests.swift
│   ├── ApprovalGateTests.swift
│   ├── EmbeddingTests.swift
│   ├── RepairmanTests.swift
│   └── ToolIntegrationTests.swift
└── docs/
    ├── ARCHITECTURE.md
    ├── DEVELOPER_GUIDE.md
    ├── EVOLUTION_GUIDE.md
    ├── OPENCLAW_INTEGRATION.md
    ├── evolutions/
    │   ├── evolve_mac_apps.py           # Batch SDEF→Tool generation
    │   ├── batch-output-313.json        # 313 evolved AppleScript tools
    │   └── import_evolved.py            # Import batch output into registry
    ├── checklists/IMPLEMENTATION_CHECKLIST.md
    ├── architecture/ADR.md
    ├── testing/TEST_PLAN.md
    └── logs/BUILD_LOG.md
```

## Build

```bash
# Debug build (fast, for development)
swift build

# Release build (optimized, for production)
swift build -c release
```

## Test

```bash
# Run all tests
swift test

# Run specific suite
swift test --filter RegistryTests
swift test --filter SDEFExtractorTests

# Note: SDEF tests and Repairman tests may be flaky when run together
# due to concurrent Process spawning. Run them sequentially:
swift test --filter SDEFExtractorTests
swift test --filter RepairmanTests
```

## Run Locally

```bash
# Test via stdin/stdout JSON-RPC
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | \
  .build/arm64-apple-macosx/debug/MCPxMacSeed

# The registry database is at:
# ~/Library/Application Support/MCPxMacSeed/tools.db
```

## Evolution Workflow

The evolution pipeline has 3 steps:

### Step 1: Extract SDEFs

Extract AppleScript dictionaries from all installed macOS apps:

```bash
python3 docs/evolutions/evolve_mac_apps.py --groq-key YOUR_KEY
```

This bypasses the LLM generation step and just extracts raw SDEF data into
`mac_app_sdefs.json` on your Desktop. For the full pipeline (SDEF → LLM → tools),
it also runs with `--mistral-key` for Mistral's free tier (1B tokens).

### Step 2: Generate Tool Schemas

The script feeds each app's SDEF commands to an LLM which generates:
- AppleScript command mappings
- MCP tool schemas with proper parameter types
- Trust/sensitivity classification

Output: `docs/evolutions/batch-output-313.json` (or custom filename)

### Step 3: Import into Registry

```bash
# Preview what will be imported (dry-run)
python3 docs/evolutions/import_evolved.py --dry-run

# Import for real
python3 docs/evolutions/import_evolved.py

# Import from custom source
python3 docs/evolutions/import_evolved.py --source my_tools.json
```

The import script:
- Reads evolved tools from JSON
- Constructs proper MCP Tool inputSchema from the evolved data
- Inserts into the SQLite registry with upsert (version increment on re-import)
- Sets consent gates for sensitive tools (delete, send, make, save, etc.)

### Step 4: Restart & Verify

```bash
openclaw gateway restart

# Verify tools are registered
# The registry should show 430+ tools across 43+ apps
```

### Step 5: Repairman Loop (Ongoing)

Not all generated tools will work first try. The Repairman captures failures and
feeds the app's SDEF back to the agent for correction. This is the self-healing
loop — the whole point of the evolution architecture.

## Adding a New Tool

1. Define the tool schema + handler in `ToolRegistrations.swift` using `registry.register()`
2. Write tests in `Tests/MCPxMacSeedTests/`
3. Build and test: `swift build && swift test`

## Code Standards

Follows the binding contract in SOUL.md and CODESTANDARDS.md:
- No stubs or mock data — every function fully implemented
- TDD: write tests first against the public interface
- Simple, boring code over clever abstractions
- Update docs after every change
- Never delete existing code unless explicitly asked
