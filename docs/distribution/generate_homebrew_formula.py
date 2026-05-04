#!/usr/bin/env python3
"""
MCP-x-Mac-Seed — Homebrew Formula Generator (unofficial, for local testing)

Generates a Homebrew formula for single-command installation.
Usage: python3 generate_formula.py > mcp-x-mac-seed.rb
"""

formula = '''class McpxMacseed < Formula
  desc "Self-evolving MCP server that gives AI agents macOS app control"
  homepage "https://github.com/USER/mcp-x-mac-seed"
  url "https://github.com/USER/mcp-x-mac-seed/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "MIT"
  version "0.1.0"

  depends_on xcode: "16"
  depends_on macos: :sequoia

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/arm64-apple-macosx/release/MCPxMacSeed" => "mcp-x-mac-seed"
    prefix.install Dir["docs/*"]
  end

  def post_install
    # Create data directory
    (var/"lib/mcp-x-mac-seed").mkpath

    # Check permissions
    ohai ""
    ohai "MCP-x-Mac-Seed installed!"
    ohai ""
    ohai "To complete setup, grant these permissions:"
    ohai "  1. System Settings → Privacy & Security → Accessibility → enable Terminal/your terminal app"
    ohai "  2. System Settings → Privacy & Security → Automation → enable for target apps"
    ohai "  3. Safari → Settings → Advanced → Show Develop menu → Develop → Allow JavaScript from Apple Events"
    ohai ""
    ohai "Test: echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}' | mcp-x-mac-seed"
    ohai ""

    # Register with OpenClaw
    ohai "To register with OpenClaw:"
    ohai "  openclaw mcp set mcp-x-mac-seed '{\"command\":\"mcp-x-mac-seed\",\"args\":[]}'"
    ohai "  openclaw gateway restart"
  end

  test do
    # Verify binary runs
    system bin/"mcp-x-mac-seed", "--version" rescue
      system "echo", "'{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}'", "|",
             bin/"mcp-x-mac-seed"
  end

  def caveats
    <<~EOS
      🔑 Permissions required:
        Accessibility: System Settings → Privacy & Security → Accessibility
        Automation: System Settings → Privacy & Security → Automation
        Safari JS: Safari → Develop → Allow JavaScript from Apple Events

      📦 Quick start:
        openclaw mcp set mcp-x-mac-seed '{"command":"mcp-x-mac-seed","args":[]}'
        openclaw gateway restart

      🧪 Test:
        Ask your AI agent: "search the web for MCP Mac Seed"
    EOS
  end
end
'''

print(formula)
