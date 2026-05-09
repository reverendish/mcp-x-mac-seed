#!/usr/bin/env python3
"""Test every tool/subtool in MCP-x-Mac-Seed.

1. Tests all 8 built-in MCP tools
2. For every scriptable app: fetches its SDEF, then executes each command
3. Produces a results file with pass/fail counts
"""

import subprocess, json, sys, os
from datetime import datetime

SERVER = os.path.join(os.path.dirname(__file__),
                      ".build/arm64-apple-macosx/debug/MCPxMacSeed")
NOW = datetime.now().strftime('%Y-%m-%d_%H%M')
OUT = f"test_results_{NOW}.txt"

builtin_tests = [
    ("scan_for_intents", {"appName": "Finder"}),
    ("list_registered_tools", {}),
    ("fetch_scripting_dictionary", {"appName": "Finder"}),
    ("get_ui_tree", {"appName": "Finder", "maxDepth": 1}),
    ("capture_screen_context", {}),
    ("request_human_approval", {"action": "check", "toolID": "1", "toolName": "finder"}),
    ("register_tool", {"name": "auto_test_ping", "app": "AutoTest", "schemaJSON": '{"type":"object"}'}),
    ("execute_intent", {"app": "Finder", "intentName": "activate"}),
]

apps = [
    "Finder", "System Events", "Mail", "Music", "Safari", "Calendar",
    "Reminders", "Notes", "Terminal", "TextEdit", "Preview", "Photos",
    "QuickTime Player", "VLC", "Spotify", "Google Chrome", "Messages",
    "Script Editor", "System Settings", "Xcode",
]

results = []

def log(msg):
    print(msg, flush=True)
    results.append(msg)
    with open(OUT, "a") as f:
        f.write(msg + "\n")


class Client:
    def __init__(self, path):
        self.p = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1
        )
        self._id = 0
        r = self._call("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "tester", "version": "1.0"}
        })
        if "error" in r:
            raise RuntimeError(f"Handshake: {r}")
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

    def _send(self, p):
        self.p.stdin.write(json.dumps(p) + "\n")
        self.p.stdin.flush()

    def _read(self):
        line = self.p.stdout.readline()
        return json.loads(line) if line.strip() else {}

    def _call(self, method, params=None):
        self._id += 1
        self._send({"jsonrpc": "2.0", "id": self._id, "method": method,
                     "params": params or {}})
        return self._read()

    def call(self, name, args):
        r = self._call("tools/call", {"name": name, "arguments": args})
        res = r.get("result", {})
        err = r.get("error", {})
        txt = "".join(c.get("text", "") for c in res.get("content", []))
        if err or res.get("isError"):
            return False, err.get("message", txt[:150])
        return True, txt[:150]

    def sdef(self, app):
        """Return list of command names from an app's SDEF."""
        ok, txt = self.call("fetch_scripting_dictionary", {"appName": app})
        if not ok:
            return []
        cmds = []
        for line in txt.split("\n"):
            line = line.strip()
            if line.startswith("- "):
                name = line[2:].split("(")[0].strip()
                if name and not name.startswith("⚠️") and not name.startswith("─"):
                    cmds.append(name)
        return cmds

    def close(self):
        self.p.stdin.close()
        self.p.terminate()
        try:
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


# ── Run ──
log(f"MCP-x-Mac-Seed — Full Tool Test")
log(f"Started: {datetime.now()}\n")

try:
    c = Client(SERVER)
except Exception as e:
    log(f"FAIL: {e}")
    sys.exit(1)

log("Server connected\n")

pass_cnt = 0
fail_cnt = 0

# ── Built-in tools ──
log("─── 1. Built-in MCP Tools ───\n")
for name, args in builtin_tests:
    ok, msg = c.call(name, args)
    flag = "✅" if ok else "❌"
    log(f"  {flag} {name} — {msg}")
    if ok:
        pass_cnt += 1
    else:
        fail_cnt += 1
log("")

# ── App SDEF command testing ──
log("─── 2. App SDEF Commands ───\n")
for app in apps:
    cmds = c.sdef(app)
    if not cmds:
        log(f"  ⏭️  {app} — no SDEF (skipping)")
        continue
    log(f"  {app} ({len(cmds)} commands):")
    for cmd in cmds:
        ok, msg = c.call("execute_intent", {"app": app, "intentName": cmd, "mode": "applescript"})
        flag = "✅" if ok else "❌"
        log(f"    {flag} {cmd} — {msg}")
        if ok:
            pass_cnt += 1
        else:
            fail_cnt += 1
    log("")

total = pass_cnt + fail_cnt
log("═══════════════════")
log(f" TOTAL:  {total}")
log(f" PASS:   {pass_cnt}")
log(f" FAIL:   {fail_cnt}")
log("═══════════════════")
log(f"\nFinished: {datetime.now()}")
log(f"Results:  {OUT}")

c.close()
sys.exit(1 if fail_cnt > 0 else 0)
