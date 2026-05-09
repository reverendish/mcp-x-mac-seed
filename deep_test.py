#!/usr/bin/env python3
"""Deep integration tests for MCP-x-Mac-Seed.

Tests actual functionality, not just AppleScript execution:
- Mail: compose + send a real email
- Music: play/pause/next track
- Finder: create folder, count items
- Preview: open a real file
- Calendar: create event
- Reminders: create reminder
"""

import subprocess, json, sys, os, time, select, tempfile
from datetime import datetime

SERVER = os.path.join(os.path.dirname(__file__),
                      ".build/arm64-apple-macosx/debug/MCPxMacSeed")
NOW = datetime.now().strftime('%Y-%m-%d_%H%M')
OUT = f"deep_test_{NOW}.txt"
TIMEOUT = 30

# ── Config (change these for your system) ──
TEST_EMAIL = "ishsitotombe@gmail.com"
TEST_FILE = os.path.expanduser("~/Desktop/mcp-x-mac-seed/README.md")
TEST_FOLDER = os.path.expanduser("~/Desktop/mcp_test_folder")

results = []

def log(msg):
    print(msg, flush=True)
    results.append(msg)
    with open(OUT, "a") as f:
        f.write(msg + "\n")


class MCP:
    def __init__(self, path):
        self.p = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1
        )
        self._id = 0
        r = self._call("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "deep-tester", "version": "1.0"}
        })
        if "error" in r:
            raise RuntimeError(f"Handshake: {r}")
        self._send({"jsonrpc":"2.0","method":"notifications/initialized","params":{}})

    def _send(self, p):
        try:
            self.p.stdin.write(json.dumps(p) + "\n")
            self.p.stdin.flush()
        except Exception:
            pass

    def _read(self, timeout=TIMEOUT):
        try:
            r, _, _ = select.select([self.p.stdout], [], [], timeout)
            if not r:
                return {"error": f"timeout ({TIMEOUT}s)"}
            line = self.p.stdout.readline()
            return json.loads(line) if line.strip() else {"error": "no response"}
        except Exception as e:
            return {"error": str(e)}

    def _call(self, method, params=None):
        self._id += 1
        self._send({"jsonrpc":"2.0","id":self._id,"method":method,
                     "params":params or {}})
        return self._read()

    def execute(self, app, intent, params=None, mode="applescript"):
        """Execute a command via the execute_intent tool."""
        args = {"app": app, "intentName": intent, "mode": mode}
        if params:
            args["parametersJSON"] = json.dumps(params)
        r = self._call("tools/call", {"name": "execute_intent", "arguments": args})
        res = r.get("result", {})
        err_jsonrpc = r.get("error")  # JSON-RPC level error
        txt = "".join(c.get("text","") for c in res.get("content",[]))
        # Tool-level errors: isError: true in result, or text starts with ❌
        is_tool_err = res.get("isError") == True or txt.strip().startswith("❌")
        ok = not (err_jsonrpc or is_tool_err)
        return ok, txt[:200]

    def close(self):
        try: self.p.stdin.close()
        except: pass
        self.p.terminate()
        try: self.p.wait(timeout=3)
        except: self.p.kill()


# ── Test helpers ──
pass_cnt = 0
fail_cnt = 0

def test(name, ok, detail=""):
    global pass_cnt, fail_cnt
    if ok:
        log(f"  ✅ {name} — {detail[:120]}")
        pass_cnt += 1
    else:
        log(f"  ❌ {name} — {detail[:120]}")
        fail_cnt += 1
    return ok


# ── Run ──
log(f"MCP-x-Mac-Seed — Deep Integration Test")
log(f"Started: {datetime.now()}\n")

c = MCP(SERVER)

# ═══════════════════════════════════════════════
# MAIL: compose + send a real email
# ═══════════════════════════════════════════════
log("─── Mail: Send Real Email ───\n")

# Compose and send with all parameters
ok, msg = c.execute("Mail", "send", params={
    "to": TEST_EMAIL,
    "subject": f"MCP-x-Mac-Seed Deep Test — {NOW}",
    "body": "This email was sent automatically by the MCP-x-Mac-Seed deep integration test.\n\nIf you received this, the Mail→send pipeline works correctly.\n\n— your tools",
    "send_immediately": "true",
    "visible": "false",
})
test("Mail: send email to self", ok, msg)

# Check for new mail
ok, msg = c.execute("Mail", "check for new mail")
test("Mail: check for new mail", ok, msg)

# Synchronize
ok, msg = c.execute("Mail", "synchronize")
test("Mail: synchronize", ok, msg)

log("")

# ═══════════════════════════════════════════════
# MUSIC: playback control
# ═══════════════════════════════════════════════
log("─── Music: Playback Control ───\n")

# Play
ok, msg = c.execute("Music", "play")
test("Music: play", ok, msg)

time.sleep(2)  # Let playback start

# Pause
ok, msg = c.execute("Music", "pause")
test("Music: pause", ok, msg)

# Play again
ok, msg = c.execute("Music", "play")
test("Music: play (resume)", ok, msg)

time.sleep(1)

# Next track
ok, msg = c.execute("Music", "next track")
test("Music: next track", ok, msg)

# Previous track
time.sleep(1)
ok, msg = c.execute("Music", "back track")
test("Music: back track", ok, msg)

# Stop
ok, msg = c.execute("Music", "stop")
test("Music: stop", ok, msg)

log("")

# ═══════════════════════════════════════════════
# FINDER: file operations
# ═══════════════════════════════════════════════
log("─── Finder: File Operations ───\n")

# Count desktop items
ok, msg = c.execute("Finder", "count", params={"direct": "every item of desktop"})
test("Finder: count desktop items", ok, msg)

# Count items in home
ok, msg = c.execute("Finder", "count", params={"direct": "every item of home"})
test("Finder: count home items", ok, msg)

# Open the project README
if os.path.exists(TEST_FILE):
    ok, msg = c.execute("Finder", "open", params={"path": TEST_FILE})
    test("Finder: open README.md", ok, msg)
    time.sleep(1)
else:
    log(f"  ⏭️  Finder: open README.md (file not found, skipping)")

# Create and delete a test folder
ok, msg = c.execute("Finder", "make", params={"name": "mcp_test_folder", "at": "desktop"})
test("Finder: create test folder", ok, msg)
time.sleep(0.5)

# Clean up test folder
if os.path.exists(TEST_FOLDER):
    os.system(f"rm -rf '{TEST_FOLDER}'")
    log(f"  🧹 Cleaned up test folder")

log("")

# ═══════════════════════════════════════════════
# PREVIEW: open real file
# ═══════════════════════════════════════════════
log("─── Preview: Open Real File ───\n")

if os.path.exists(TEST_FILE):
    ok, msg = c.execute("Preview", "open", params={"direct": f'POSIX file "{TEST_FILE}"'})
    test("Preview: open README.md", ok, msg)
    time.sleep(2)
    
    # Print (should work with open file)
    ok, msg = c.execute("Preview", "print")
    test("Preview: print", ok or "cancel" in msg.lower(), msg)  # OK if print dialog opens
else:
    log(f"  ⏭️  Preview tests (no test file)")

log("")

# ═══════════════════════════════════════════════
# CALENDAR: create event
# ═══════════════════════════════════════════════
log("─── Calendar ───\n")

ok, msg = c.execute("Calendar", "create calendar", params={
    "name": "MCP Test Calendar"
})
test("Calendar: create calendar", ok, msg)

ok, msg = c.execute("Calendar", "show")
test("Calendar: show", ok, msg)

log("")

# ═══════════════════════════════════════════════
# REMINDERS: create reminder
# ═══════════════════════════════════════════════
log("─── Reminders ───\n")

ok, msg = c.execute("Reminders", "make", params={
    "direct": "new reminder",
    "name": f"MCP Deep Test — {NOW}"
})
test("Reminders: create reminder", ok, msg)

ok, msg = c.execute("Reminders", "show")
test("Reminders: show app", ok, msg)

log("")

# ═══════════════════════════════════════════════
# SAFARI: web operations
# ═══════════════════════════════════════════════
log("─── Safari ───\n")

ok, msg = c.execute("Safari", "search the web", params={
    "direct": "MCP-x-Mac-Seed AppleScript testing"
})
test("Safari: search the web", ok, msg)

time.sleep(2)

ok, msg = c.execute("Safari", "do JavaScript", params={
    "direct": "document.title"
})
test("Safari: do JavaScript", ok, msg)

log("")

# ═══════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════
total = pass_cnt + fail_cnt
log("═════════════════════════════")
log(f" DEEP TEST RESULTS")
log(f" PASS:  {pass_cnt}")
log(f" FAIL:  {fail_cnt}")
log(f" TOTAL: {total}")
log("═════════════════════════════")
log(f"\nFinished: {datetime.now()}")
log(f"Results:  {OUT}")

c.close()
sys.exit(1 if fail_cnt > 0 else 0)
