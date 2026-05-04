#!/usr/bin/env python3
"""
Batch Repair Script for MCP-x-Mac-Seed evolved tools.

For each evolved tool that lacks an `appleScript` field, auto-generates one
from the app's SDEF and re-registers via direct SQLite update.

Usage:
    python3 batch_repair.py           # preview which tools need repair
    python3 batch_repair.py --apply   # actually repair + update registry
"""

import json
import os
import sqlite3
import subprocess
import sys
import re
from datetime import datetime, timezone

REGISTRY_DB = os.path.expanduser(
    "~/Library/Application Support/MCPxMacSeed/tools.db"
)
EVOLVED_TOOLS = os.path.join(
    os.path.dirname(__file__), "batch-output-313.json"
)


def load_sdef(app_name):
    """Run /usr/bin/sdef and parse command names → appleScript hints."""
    # Find app path
    dirs = [
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications",
        "/Applications/Utilities",
    ]
    app_path = None
    for d in dirs:
        # Also check bundle ID
        for item in os.listdir(d) if os.path.isdir(d) else []:
            name = item[:-4] if item.endswith(".app") else item
            if name.lower() == app_name.lower():
                app_path = os.path.join(d, item)
                break
        if app_path:
            break

    if not app_path:
        # Try by app name directly
        result = subprocess.run(
            ["mdfind", f"kMDItemKind == 'Application' && kMDItemDisplayName == '{app_name}.app'"],
            capture_output=True, text=True, timeout=10
        )
        paths = result.stdout.strip().split("\n")
        if paths and paths[0]:
            app_path = paths[0]

    if not app_path or not os.path.exists(app_path):
        return {}

    result = subprocess.run(
        ["/usr/bin/sdef", app_path],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0 or not result.stdout.strip():
        return {}

    xml = result.stdout

    # Parse commands from SDEF XML
    commands = {}
    pattern = r'<command\s+name="([^"]*)"[^>]*\s*(?:description="([^"]*)")?'
    for match in re.finditer(pattern, xml):
        cmd_name = match.group(1)
        desc = match.group(2) or ""
        if not cmd_name:
            continue

        # Get command context (parameters)
        cmd_start = match.start()
        cmd_end = xml.find("</command>", cmd_start)
        if cmd_end < 0:
            cmd_end = xml.find("/>", cmd_start) + 2
            if cmd_end < 2:
                continue
        else:
            cmd_end += 10
        cmd_xml = xml[cmd_start:cmd_end]

        # Extract parameters
        params = []
        dp_match = re.search(r'<direct-parameter[^>]*type="([^"]*)"[^>]*description="([^"]*)"', cmd_xml)
        if dp_match:
            params.append({
                "name": "value",
                "type": dp_match.group(1),
                "desc": dp_match.group(2),
                "is_direct": True,
            })
        for pm in re.finditer(r'<parameter\s+name="([^"]*)"[^>]*type="([^"]*)"[^>]*(?:description="([^"]*)")?', cmd_xml):
            params.append({
                "name": pm.group(1),
                "type": pm.group(2),
                "desc": pm.group(3) or "",
                "is_direct": False,
            })

        commands[cmd_name] = {
            "description": desc,
            "parameters": params,
        }

    return commands


def generate_applescript(app_name, sdef_cmd_name, params):
    """Generate an AppleScript string from SDEF command info."""
    script = f'tell application "{app_name}"\n'

    # Determine command syntax based on parameters
    if not params:
        script += f"    {sdef_cmd_name}\n"
    elif len(params) == 1 and params[0]["is_direct"]:
        val = params[0]["name"]
        script += f'    {sdef_cmd_name} "{{{val}}}"\n'
    else:
        script += f"    {sdef_cmd_name}"
        for p in params:
            if p["is_direct"]:
                script += f' "{{{p["name"]}}}"'
            else:
                script += f' {p["name"]}:"{{{p["name"]}}}"'
        script += "\n"

    script += "end tell"
    return script


def fuzzy_match_tool_to_sdef(tool_name, sdef_commands):
    """Match a tool name like 'mail_check_for_new_mail' to SDEF command 'check for new mail'."""
    # Strip app prefix, normalize to spaces
    parts = tool_name.split("_", 1)
    search = parts[1] if len(parts) > 1 else parts[0]
    search_lower = search.lower()

    # Exact
    for cmd in sdef_commands:
        if cmd.lower() == search_lower:
            return cmd, 1.0

    # Space-normalized
    space = search_lower.replace("_", " ")
    for cmd in sdef_commands:
        if cmd.lower() == space:
            return cmd, 0.95

    # Close → quit
    if search_lower == "close" and "quit" in [c.lower() for c in sdef_commands]:
        return "quit", 0.95

    # Substring
    best = None
    for cmd in sdef_commands:
        if cmd.lower().replace(" ", "") in space.replace(" ", ""):
            score = len(cmd) / max(len(space), 1)
            if score > (best[1] if best else 0.3):
                best = (cmd, score * 0.5)

    return best or (None, 0)


def repair_tools(apply=False):
    """Main repair loop: load tools, match to SDEFs, generate AppleScript, update registry."""
    with open(EVOLVED_TOOLS) as f:
        tools = json.load(f)

    repairs = 0
    skipped = 0
    no_sdef = 0
    no_match = 0

    # Cache SDEFs
    sdef_cache = {}

    for i, tool in enumerate(tools):
        name = tool.get("name", "")
        app = tool.get("app", "")
        if not name or not app:
            skipped += 1
            continue

        # Skip if already has appleScript
        if tool.get("appleScript"):
            skipped += 1
            continue

        # Load SDEF
        if app not in sdef_cache:
            sdef_cache[app] = load_sdef(app)

        sdef = sdef_cache[app]
        if not sdef:
            no_sdef += 1
            continue

        # Match tool to SDEF command
        cmd_name, confidence = fuzzy_match_tool_to_sdef(name, sdef)
        if not cmd_name or confidence < 0.9:
            no_match += 1
            continue

        # Skip standard AppleScript commands — the ExecutionEngine handles these
        # via Tier 1 (hardcoded) or Tier 3 (heuristic). SDEF repair produces
        # wrong scripts for commands like close/delete/make that need specifiers.
        standard_cmds = {"close", "delete", "count", "duplicate", "exists",
                        "get", "make", "move", "save", "set", "open", "print",
                        "quit", "activate", "copy", "select", "add", "remove"}
        if cmd_name.lower() in standard_cmds:
            skipped += 1
            continue

        # Generate AppleScript
        cmd_info = sdef[cmd_name]
        script = generate_applescript(app, cmd_name, cmd_info["parameters"])

        # Update tool
        tool["appleScript"] = script

        # Build proper inputSchema from SDEF params
        props = {}
        required = []
        for p in cmd_info["parameters"]:
            if p["is_direct"]:
                key = "value"
            else:
                key = p["name"]
            props[key] = {"type": "string", "description": p["desc"]}
            if not p.get("optional", True):
                required.append(key)

        tool["inputSchema"] = {
            "type": "object",
            "properties": props,
            "required": required,
        }

        repairs += 1

        if apply:
            # Update SQLite registry
            conn = sqlite3.connect(REGISTRY_DB)
            conn.row_factory = sqlite3.Row
            now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            schema_json = json.dumps(tool)
            cursor = conn.cursor()
            cursor.execute(
                "SELECT id, version FROM tools WHERE app = ? AND name = ?",
                (app, name)
            )
            existing = cursor.fetchone()
            if existing:
                new_version = existing["version"] + 1
                cursor.execute(
                    "UPDATE tools SET schema_json = ?, version = ?, status = 'active', "
                    "last_error = NULL, updated_at = ? WHERE id = ?",
                    (schema_json, new_version, now, existing["id"]),
                )
            else:
                cursor.execute(
                    "INSERT INTO tools (name, app, version, schema_json, status, "
                    "requires_approval, created_at, updated_at) "
                    "VALUES (?, ?, 1, ?, 'active', ?, ?, ?)",
                    (name, app, schema_json, 1 if tool.get("isSensitive") else 0, now, now),
                )
            conn.commit()
            conn.close()

        if (i + 1) % 50 == 0 or i == len(tools) - 1:
            print(f"  Progress: {i+1}/{len(tools)} ({repairs} repaired, {no_match} no match, {no_sdef} no SDEF)")

    # Save updated tools
    output_path = EVOLVED_TOOLS.replace(".json", "-repaired.json")
    with open(output_path, "w") as f:
        json.dump(tools, f, indent=2)

    print(f"\n{'='*50}")
    print(f"  Repaired:  {repairs}")
    print(f"  No SDEF:   {no_sdef}")
    print(f"  No match:  {no_match}")
    print(f"  Skipped:   {skipped}")
    if apply:
        print(f"  Registry updated ✅")
        print(f"  Restart MCP: openclaw gateway restart")
    else:
        print(f"  DRY RUN — use --apply to commit changes")
    print(f"  Output: {output_path}")
    print(f"{'='*50}")


if __name__ == "__main__":
    apply = "--apply" in sys.argv
    if not apply:
        print("DRY RUN — use --apply to actually repair\n")
    repair_tools(apply=apply)
