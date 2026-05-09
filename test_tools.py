#!/usr/bin/env python3
"""Test every MCP-x-Mac-Seed tool/subtool via MCP protocol over stdio.

Tests all 8 built-in tools + SDEF commands for all scriptable apps.
Skips system-level and UI-automation commands. Per-command timeout via
stdio read deadline.
"""

import subprocess, json, sys, os, time, signal, select
from datetime import datetime

SERVER = os.path.join(os.path.dirname(__file__),
                      ".build/arm64-apple-macosx/debug/MCPxMacSeed")
NOW = datetime.now().strftime('%Y-%m-%d_%H%M')
OUT = f"test_results_{NOW}.txt"
CMD_TIMEOUT = 20  # seconds per command

SKIP_COMMANDS = {
    # Finder: system-level
    "restart", "shut down", "shut_down", "sleep", "log out", "log_out",
}
SKIP_APPS = {
    # System Events: raw UI automation, many commands hang
    "System Events",
}

APPS = [
    "Finder", "Mail", "Music", "Safari", "Calendar", "Reminders",
    "Notes", "Terminal", "TextEdit", "Preview", "Photos",
    "QuickTime Player", "Script Editor", "System Settings",
]

BUILTINS = [
    ("scan_for_intents",           {"appName": "Finder"}),
    ("list_registered_tools",      {}),
    ("fetch_scripting_dictionary", {"appName": "Finder"}),
    ("get_ui_tree",               {"appName": "Finder", "maxDepth": 1}),
    ("capture_screen_context",    {}),
    ("request_human_approval",    {"action":"check","toolID":"1","toolName":"finder"}),
    ("register_tool",             {"name":"auto_test_ping","app":"AutoTest","schemaJSON":'{"type":"object"}'}),
    ("execute_intent",            {"app":"Finder","intentName":"activate"}),
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
        self._send({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})

    def _send(self, p):
        try:
            self.p.stdin.write(json.dumps(p) + "\n")
            self.p.stdin.flush()
            return True
        except Exception:
            return False

    def _read(self, timeout=CMD_TIMEOUT):
        try:
            r, _, _ = select.select([self.p.stdout], [], [], timeout)
            if not r:
                return None  # timeout
            line = self.p.stdout.readline()
            return json.loads(line) if line.strip() else None
        except Exception:
            return None

    def _call(self, method, params=None):
        self._id += 1
        if not self._send({"jsonrpc":"2.0","id":self._id,"method":method,
                           "params":params or {}}):
            return {"error":"server dead"}
        r = self._read()
        if r is None:
            return {"error": f"timeout ({CMD_TIMEOUT}s)"}
        return r

    def call(self, name, args):
        r = self._call("tools/call", {"name": name, "arguments": args})
        res = r.get("result", {})
        err = r.get("error", {})
        txt = "".join(c.get("text","") for c in res.get("content",[]))
        data = res.get("structuredContent")
        if isinstance(data, dict) and "dictionary" in data:
            data = data["dictionary"]
        if err or res.get("isError"):
            if isinstance(err, dict):
                return False, err.get("message", txt[:100]), data
            return False, str(err)[:100], data
        return True, txt[:100], data

    def sdef_commands(self, app):
        ok, _, data = self.call("fetch_scripting_dictionary", {"appName": app})
        if not ok or not data:
            return []
        return [c["name"] for c in data.get("commands",[]) if c.get("name")]

    def alive(self):
        return self.p.poll() is None

    def close(self):
        try: self.p.stdin.close()
        except: pass
        self.p.terminate()
        try: self.p.wait(timeout=3)
        except: self.p.kill()


# ── Run ──
log(f"MCP-x-Mac-Seed — Full Tool Test")
log(f"Started: {datetime.now()}")
log(f"Timeout: {CMD_TIMEOUT}s per command\n")

try:
    c = Client(SERVER)
except Exception as e:
    log(f"FAIL: {e}")
    sys.exit(1)

log("✅ Server connected\n")

pass_cnt = fail_cnt = skip_cnt = 0

# ── 1. Built-in ──
log("─── 1. Built-in MCP Tools ───\n")
for name, args in BUILTINS:
    ok, msg, _ = c.call(name, args)
    emoji = "✅" if ok else "❌"
    log(f"  {emoji} {name} — {msg[:120]}")
    if ok: pass_cnt += 1
    else: fail_cnt += 1
log("")

# ── 2. App SDEF commands ──
log("─── 2. App SDEF Commands ───\n")
for app in APPS:
    if app in SKIP_APPS:
        log(f"  ⏭️  {app} — skipped (known hanger)")
        skip_cnt += 1
        continue

    if not c.alive():
        c.close(); time.sleep(1)
        try: c = Client(SERVER)
        except: log(f"  ❌ Server died, can't restart"); break

    cmds = c.sdef_commands(app)
    if not cmds:
        log(f"  ⏭️  {app} — no SDEF")
        skip_cnt += 1
        continue

    app_pass = app_fail = app_skip = 0
    for cmd in cmds:
        if cmd.lower() in SKIP_COMMANDS:
            log(f"    ⏭️  {cmd} (system-level, skipped)")
            app_skip += 1; skip_cnt += 1
            continue

        ok, msg, _ = c.call("execute_intent", {"app":app,"intentName":cmd,"mode":"applescript"})
        emoji = "✅" if ok else "❌"
        log(f"    {emoji} {cmd} — {msg[:100]}")
        if ok: pass_cnt += 1; app_pass += 1
        else: fail_cnt += 1; app_fail += 1

        if not c.alive():
            log(f"    ⚠️ Server died, restarting...")
            c.close(); time.sleep(1)
            try: c = Client(SERVER)
            except: log(f"    ❌ Can't restart"); break

    log(f"  → {app}: {app_pass} pass, {app_fail} fail, {app_skip} skipped\n")

total = pass_cnt + fail_cnt + skip_cnt
log("═══════════════════")
log(f" TOTAL:    {total}")
log(f" PASS:     {pass_cnt}")
log(f" FAIL:     {fail_cnt}")
log(f" SKIPPED:  {skip_cnt}")
log("═══════════════════")
log(f"\nFinished: {datetime.now()}")
log(f"Results:  {OUT}")

c.close()
sys.exit(1 if fail_cnt > 0 else 0)
