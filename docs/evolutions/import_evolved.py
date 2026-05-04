#!/usr/bin/env python3
"""
Import evolved tools into the MCP-x-Mac-Seed SQLite registry.

Reads batch-output-313.json and inserts each tool into the registry database
at ~/Library/Application Support/MCPxMacSeed/tools.db.

Usage:
    python3 import_evolved.py
    python3 import_evolved.py --dry-run          # preview only
    python3 import_evolved.py --source output.json  # custom source
"""

import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

# Paths
DEFAULT_SOURCE = os.path.join(
    os.path.dirname(__file__), "batch-output-313.json"
)
REGISTRY_DB = os.path.expanduser(
    "~/Library/Application Support/MCPxMacSeed/tools.db"
)


def load_evolved_tools(path):
    """Load evolved tools from JSON file."""
    with open(path) as f:
        tools = json.load(f)
    print(f"  Loaded {len(tools)} tools from {path}")
    return tools


def build_schema_json(tool):
    """Build the MCP Tool inputSchema JSON string for an evolved tool.
    
    The schema describes the parameters the tool accepts, matching the
    evolved tool's inputSchema. This is what the MCP client uses to
    present the tool to the AI agent.
    """
    schema = {
        "type": "object",
        "properties": {},
        "required": []
    }

    # Copy properties from the evolved tool's inputSchema
    evolved_schema = tool.get("inputSchema", {})
    if isinstance(evolved_schema, dict):
        schema["properties"] = evolved_schema.get("properties", {})
        schema["required"] = evolved_schema.get("required", [])

    return json.dumps(schema)


def import_tools(tools, db_path, dry_run=False):
    """Insert each evolved tool into the SQLite registry."""
    if dry_run:
        print("\n  [DRY RUN] No changes will be made\n")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Verify schema
    cursor.execute("PRAGMA table_info(tools)")
    columns = [row["name"] for row in cursor.fetchall()]
    required = {"name", "app", "version", "schema_json", "status",
                "requires_approval", "created_at", "updated_at"}
    missing = required - set(columns)
    if missing:
        print(f"  ERROR: Registry table missing columns: {missing}")
        sys.exit(1)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    inserted = 0
    updated = 0
    errors = 0

    for tool in tools:
        name = tool.get("name", "").strip()
        app = tool.get("app", "").strip()
        if not name or not app:
            print(f"  ⏭ Skipping tool with empty name/app: {name} / {app}")
            errors += 1
            continue

        schema_json = build_schema_json(tool)
        requires_approval = 1 if tool.get("isSensitive", False) else 0

        if dry_run:
            print(
                f"  Would insert: {name} [{app}] "
                f"{'🔒' if requires_approval else ''}"
            )
            inserted += 1
            continue

        # Check if tool already exists
        cursor.execute(
            "SELECT id, version FROM tools WHERE app = ? AND name = ?",
            (app, name)
        )
        existing = cursor.fetchone()

        if existing:
            # Upsert: increment version, update schema + status
            new_version = existing["version"] + 1
            cursor.execute(
                """
                UPDATE tools
                SET schema_json = ?,
                    version = ?,
                    status = 'active',
                    requires_approval = ?,
                    last_error = NULL,
                    updated_at = ?
                WHERE id = ?
                """,
                (schema_json, new_version, requires_approval, now,
                 existing["id"])
            )
            updated += 1
        else:
            # Fresh insert
            cursor.execute(
                """
                INSERT INTO tools
                    (name, app, version, schema_json, status,
                     requires_approval, created_at, updated_at)
                VALUES (?, ?, 1, ?, 'active', ?, ?, ?)
                """,
                (name, app, schema_json, requires_approval, now, now)
            )
            inserted += 1

    if not dry_run:
        conn.commit()

    conn.close()
    return inserted, updated, errors


def main():
    dry_run = "--dry-run" in sys.argv
    source = DEFAULT_SOURCE

    # Check for --source override
    for i, arg in enumerate(sys.argv):
        if arg == "--source" and i + 1 < len(sys.argv):
            source = sys.argv[i + 1]

    if not os.path.exists(source):
        print(f"ERROR: Source file not found: {source}")
        sys.exit(1)

    if not os.path.exists(REGISTRY_DB):
        print(f"ERROR: Registry database not found at: {REGISTRY_DB}")
        print("  Make sure the MCP-x-Mac-Seed server has been started at least once.")
        print("  Run: swift build && .build/arm64-apple-macosx/debug/MCPxMacSeed")
        sys.exit(1)

    print(f"  Source: {source}")
    print(f"  Registry: {REGISTRY_DB}")
    if dry_run:
        print("  Mode: DRY RUN")

    tools = load_evolved_tools(source)
    inserted, updated, errors = import_tools(tools, REGISTRY_DB, dry_run)

    print(f"\n{'=' * 50}")
    if dry_run:
        print(f"  DRY RUN — {inserted} tools would be inserted")
        print(f"  {errors} tool(s) would be skipped")
    else:
        print(f"  ✅ Import complete!")
        print(f"  Inserted: {inserted}")
        print(f"  Updated:  {updated}")
        print(f"  Errors:   {errors}")
        total = inserted + updated
        print(f"  Registry now has {total} (+{total - errors}) evolved tools")
    print(f"{'=' * 50}")


if __name__ == "__main__":
    main()
