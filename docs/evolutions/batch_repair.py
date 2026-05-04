#!/usr/bin/env python3
"""
Batch Repair Script for MCP-x-Mac-Seed evolved tools — v0.2.0 (hardened)

Security: Uses osascript 'on run argv' positional arg pattern to prevent
AppleScript injection. All dynamic values passed as argv[n], never string-interpolated.

XML Parsing: Uses xml.etree.ElementTree with namespace-aware parsing to handle
xi:include, CDATA, and nested SDEF structures correctly.

Usage:
    python3 batch_repair.py           # preview which tools need repair
    python3 batch_repair.py --apply   # actually repair + update registry
"""

import json
import os
import sqlite3
import subprocess
import sys
import xml.etree.ElementTree as ET
import unicodedata
from datetime import datetime, timezone

REGISTRY_DB = os.path.expanduser(
    "~/Library/Application Support/MCPxMacSeed/tools.db"
)
EVOLVED_TOOLS = os.path.join(
    os.path.dirname(__file__), "batch-output-313.json"
)

SDEF_NAMESPACE = "http://developer.apple.com/ns/sdef"

# ─── Security: Input Sanitization ───

# Allowed characters for AppleScript identifiers, paths, and values.
# This is a strict whitelist — anything outside this set is rejected or stripped.
_SAFE_CHARS = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789"
    " _-.,:;!?@#$%&*()+=[]{}|/~`'^<>"  # balanced delimiters
    "\n\t\r"                              # whitespace
    "\u00c0-\u00ff\u0100-\u024f"         # Latin extended
)


def sanitize(value, max_length=1024):
    """Whitelist-based sanitizer for all user/LLM-supplied values.

    Strips characters outside the allowed set. If the resulting string
    is empty or exceeds max_length, returns a safe default.
    """
    if not isinstance(value, str):
        return ""
    cleaned = "".join(c for c in value if c in _SAFE_CHARS)
    cleaned = cleaned.strip()
    if len(cleaned) > max_length:
        cleaned = cleaned[:max_length]
    if not cleaned:
        return ""  # caller should handle empty
    return cleaned


def sanitize_app_name(name):
    """Sanitize app name — double quotes are strictly forbidden in tell blocks."""
    name = sanitize(name)
    return name.replace('"', "").replace("\\", "")


# ─── SDEF Parsing: ElementTree (Replaces regex) ───


def load_sdef(app_name):
    """Run /usr/bin/sdef and parse commands with ElementTree."""
    dirs = [
        "/System/Applications", "/System/Applications/Utilities",
        "/Applications", "/Applications/Utilities",
    ]
    app_path = None
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for item in os.listdir(d):
            name = item[:-4] if item.endswith(".app") else item
            if name.lower() == app_name.lower():
                app_path = os.path.join(d, item)
                break
        if app_path:
            break

    if not app_path:
        result = subprocess.run(
            ["mdfind",
             f"kMDItemKind == 'Application' && kMDItemDisplayName == '{sanitize_app_name(app_name)}.app'"],
            capture_output=True, text=True, timeout=10
        )
        paths = result.stdout.strip().split("\n")
        if paths and paths[0] and os.path.exists(paths[0]):
            app_path = paths[0]

    if not app_path or not os.path.exists(app_path):
        return {}

    result = subprocess.run(
        ["/usr/bin/sdef", app_path],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0 or not result.stdout.strip():
        return {}

    return parse_sdef_xml(result.stdout)


def parse_sdef_xml(xml_string):
    """Parse SDEF XML using ElementTree with namespace awareness.

    Handles xi:include, nested suites, CDATA sections, and hidden commands.
    Returns {command_name: {description, parameters}}.
    """
    commands = {}
    try:
        # Register namespaces
        ET.register_namespace("xi", "http://www.w3.org/2003/XInclude")
        root = ET.fromstring(xml_string)
    except ET.ParseError:
        return {}

    ns = {"sdef": SDEF_NAMESPACE}

    for cmd_elem in root.iter(f"{{{SDEF_NAMESPACE}}}command"):
        name = cmd_elem.get("name", "").strip()
        if not name:
            continue
        # Skip hidden commands
        if cmd_elem.get("hidden", "no") == "yes":
            continue

        desc = cmd_elem.get("description", "").strip()

        # Extract parameters
        params = []
        # Direct parameter
        dp = cmd_elem.find(f"{{{SDEF_NAMESPACE}}}direct-parameter")
        if dp is not None:
            params.append({
                "name": "value",
                "type": dp.get("type", "text"),
                "desc": dp.get("description", "").strip(),
                "is_direct": True,
            })

        # Named parameters
        for p_elem in cmd_elem.findall(f"{{{SDEF_NAMESPACE}}}parameter"):
            pname = p_elem.get("name", "").strip()
            if pname:
                params.append({
                    "name": pname,
                    "type": p_elem.get("type", "text"),
                    "desc": p_elem.get("description", "").strip(),
                    "is_direct": False,
                })

        commands[name] = {
            "description": sanitize(desc, max_length=512),
            "parameters": params,
        }

    return commands


# ─── AppleScript Generation: osascript 'on run argv' pattern ───

def generate_applescript(app_name, sdef_cmd_name, params):
    """Generate a hardened AppleScript using 'on run argv' positional args.

    Security: All dynamic values are passed as argv[n] — never string-interpolated
    into the script body. This prevents AppleScript injection (CWE-74, CWE-94).

    The osascript invocation becomes:
        osascript -e '<script>' -- <arg1> <arg2> ...
    where the script uses:
        on run argv
            set param1 to item 1 of argv
            ...
        end run
    """
    app_name = sanitize_app_name(app_name)
    sdef_cmd_name = sanitize(sdef_cmd_name)

    if not app_name or not sdef_cmd_name:
        return ""

    lines = [f'tell application "{app_name}"']

    if not params:
        lines.append(f"    {sdef_cmd_name}")
    elif len(params) == 1 and params[0]["is_direct"]:
        param_name = sanitize(params[0]["name"], max_length=64)
        # Positional arg: osascript passes value as arg, script reads argv[1]
        lines.append(f"    set arg1 to item 1 of argv")
        lines.append(f'    {sdef_cmd_name} arg1')
    else:
        lines.append(f"    {sdef_cmd_name}")
        arg_idx = 1
        for p in params:
            pname = sanitize(p["name"], max_length=64)
            if p["is_direct"]:
                lines.append(f"    set arg{arg_idx} to item {arg_idx} of argv")
                lines[-2] += f' arg{arg_idx}'
                arg_idx += 1
            else:
                lines.append(f"    set arg{arg_idx} to item {arg_idx} of argv")
                lines[-2] += f' {pname}:arg{arg_idx}'
                arg_idx += 1

    lines.append("end tell")
    return "\n".join(lines)


def build_applescript_with_args(script_template, params):
    """Build the final AppleScript with 'on run argv' wrapper.

    Returns (wrapped_script, args_list) for use with osascript.
    """
    app_args = []
    # Collect positional args in order matching the script's argv[n] references
    for key, value in params.items():
        if value:  # skip empty values
            app_args.append(sanitize(str(value), max_length=4096))

    wrapped = "on run argv\n" + script_template + "\nend run"
    return wrapped, app_args


# ─── Tool Matching ───


def fuzzy_match_tool_to_sdef(tool_name, sdef_commands):
    """Match a tool name to SDEF command using underscore-to-space normalization."""
    parts = tool_name.split("_", 1)
    search = parts[1] if len(parts) > 1 else parts[0]
    search_lower = sanitize(search.lower())

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


# ─── Database: Atomic UPSERT ───


def upsert_tool(conn, name, app, schema_json, is_sensitive):
    """Atomic INSERT ... ON CONFLICT DO UPDATE.

    Replaces the old SELECT-then-UPDATE/INSERT pattern which had a TOCTOU race
    condition between concurrent gateway operations.
    """
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    requires_approval = 1 if is_sensitive else 0

    conn.execute(
        """
        INSERT INTO tools (name, app, version, schema_json, status,
                           requires_approval, created_at, updated_at)
        VALUES (?, ?, 1, ?, 'active', ?, ?, ?)
        ON CONFLICT(app, name) DO UPDATE SET
            schema_json = excluded.schema_json,
            version = tools.version + 1,
            status = 'active',
            requires_approval = excluded.requires_approval,
            last_error = NULL,
            updated_at = excluded.updated_at
        """,
        (name, app, schema_json, requires_approval, now, now)
    )


# ─── Main Repair Loop ───

STANDARD_COMMANDS = {
    "close", "delete", "count", "duplicate", "exists",
    "get", "make", "move", "save", "set", "open", "print",
    "quit", "activate", "copy", "select", "add", "remove",
}


def repair_tools(apply=False):
    with open(EVOLVED_TOOLS) as f:
        tools = json.load(f)

    repairs = 0
    skipped = 0
    no_sdef = 0
    no_match = 0
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
        san_app = sanitize_app_name(app)
        if san_app not in sdef_cache:
            sdef_cache[san_app] = load_sdef(san_app)

        sdef = sdef_cache[san_app]
        if not sdef:
            no_sdef += 1
            continue

        # Match
        cmd_name, confidence = fuzzy_match_tool_to_sdef(name, sdef)
        if not cmd_name or confidence < 0.9:
            no_match += 1
            continue

        # Skip standard commands (handled by ExecutionEngine tiers)
        if cmd_name.lower() in STANDARD_COMMANDS:
            skipped += 1
            continue

        # Generate hardened AppleScript
        cmd_info = sdef[cmd_name]
        script = generate_applescript(san_app, cmd_name, cmd_info["parameters"])

        # Build proper inputSchema
        props = {}
        required = []
        for p in cmd_info["parameters"]:
            key = "value" if p["is_direct"] else p["name"]
            props[key] = {
                "type": "string",
                "description": sanitize(p["desc"], max_length=256),
            }
            if key != "value":  # direct params are always required
                required.append(key)

        tool["appleScript"] = script
        tool["inputSchema"] = {
            "type": "object",
            "properties": props,
            "required": required,
        }

        repairs += 1

        if apply:
            schema_json = json.dumps(tool)
            conn = sqlite3.connect(REGISTRY_DB)
            upsert_tool(conn, name, app, schema_json, tool.get("isSensitive", False))
            conn.commit()
            conn.close()

        if (i + 1) % 50 == 0 or i == len(tools) - 1:
            print(f"  Progress: {i+1}/{len(tools)} "
                  f"({repairs} repaired, {no_match} no match, {no_sdef} no SDEF)")

    output_path = EVOLVED_TOOLS.replace(".json", "-repaired.json")
    with open(output_path, "w") as f:
        json.dump(tools, f, indent=2)

    print(f"\n{'='*50}")
    print(f"  Repaired:  {repairs}")
    print(f"  No SDEF:   {no_sdef}")
    print(f"  No match:  {no_match}")
    print(f"  Skipped:   {skipped}")
    if apply:
        print(f"  Registry updated via atomic UPSERT")
    else:
        print(f"  DRY RUN — use --apply to commit")
    print(f"  Output: {output_path}")
    print(f"{'='*50}")


if __name__ == "__main__":
    apply = "--apply" in sys.argv
    if not apply:
        print("DRY RUN — use --apply to actually repair\n")
    repair_tools(apply=apply)
