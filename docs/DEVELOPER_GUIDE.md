# MCP-x-Mac Seed Server — Developer Guide

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
