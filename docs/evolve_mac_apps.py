#!/usr/bin/env python3
"""
Batch evolution tool for MCP-x-Mac-Seed.
Extracts SDEFs from all macOS apps, sends each command to Groq's free LLM,
and generates production-quality AppleScript + MCP tool schemas.

Usage:
    python3 evolve_mac_apps.py --groq-key gsk_YOUR_KEY_HERE
    python3 evolve_mac_apps.py --groq-key gsk_YOUR_KEY_HERE --app Calendar --app Music
    python3 evolve_mac_apps.py --groq-key gsk_YOUR_KEY_HERE --resume                 # resume from cache
"""

import os, sys, json, subprocess, xml.etree.ElementTree as ET, time, argparse, glob

# ─── Configuration ───
CACHE_FILE = os.path.expanduser("~/.mcp_evolution_cache.json")
OUTPUT_FILE = "evolved_tools.json"

# ─── Step 1: Extract SDEFs ───
def extract_sdefs(target_apps=None):
    """Run sdef on all standard macOS apps and return structured data."""
    dirs = [
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications",
        "/Applications/Utilities",
    ]
    
    skip = {"automator application stub", "automator runner", "feedback assistant"}
    apps = []
    
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for item in sorted(os.listdir(d)):
            if not item.endswith(".app") or item.startswith("."):
                continue
            name = item[:-4]
            if name.lower() in skip:
                continue
            if target_apps and name not in target_apps:
                continue
            
            path = os.path.join(d, item)
            try:
                result = subprocess.run(
                    ["/usr/bin/sdef", path],
                    capture_output=True, text=True, timeout=10
                )
                if result.returncode == 0 and result.stdout.strip():
                    apps.append({"name": name, "sdef_xml": result.stdout})
                    print(f"  ✅ {name}")
                else:
                    print(f"  ⏭ {name} (no SDEF)")
            except subprocess.TimeoutExpired:
                print(f"  ⏭ {name} (timeout)")
            except Exception as e:
                print(f"  ⏭ {name} ({e})")
    
    return apps

# ─── Step 2: Parse SDEF XML to commands ───
def parse_sdef(app_data):
    """Convert raw SDEF XML to structured command list."""
    namespaces = {"sdef": "http://developer.apple.com/ns/sdef"}
    commands = []
    
    try:
        root = ET.fromstring(app_data["sdef_xml"])
        
        for cmd in root.iter("{http://developer.apple.com/ns/sdef}command"):
            name = cmd.get("name", "")
            if cmd.get("hidden", "no") == "yes" or not name:
                continue
            
            params = []
            for p in cmd.findall("{http://developer.apple.com/ns/sdef}parameter"):
                params.append({
                    "name": p.get("name", ""),
                    "type": p.get("type", "any"),
                    "description": p.get("description", ""),
                    "optional": p.get("optional", "no") == "yes"
                })
            
            dp = cmd.find("{http://developer.apple.com/ns/sdef}direct-parameter")
            if dp is not None:
                params.insert(0, {
                    "name": "direct",
                    "type": dp.get("type", "any"),
                    "description": dp.get("description", ""),
                    "optional": False
                })
            
            commands.append({
                "name": name,
                "description": cmd.get("description", ""),
                "parameters": params
            })
    except Exception:
        pass
    
    return commands

# ─── Step 3: Generate tool via Groq ───
def generate_tool(groq_client, app_name, command, model="llama-3.3-70b-versatile"):
    """Send one command to Groq LLM and get back a production tool schema."""
    
    prompt = f"""You are an AppleScript automation expert. Given a macOS app and a command from its scripting dictionary, output JSON for an MCP tool.

App: {app_name}
Command name: "{command['name']}"
Description: {command['description']}
Parameters:"""

    for p in command["parameters"]:
        prompt += f'\n  - {p["name"]}: {p["type"]} (optional: {p["optional"]}) — {p["description"]}'

    prompt += """

Output JSON with:
- "name": tool name like "{app_small}_{command_small}"
- "description": what this tool does
- "app": the app name
- "strategy": "applescript"
- "isSensitive": true if this modifies/deletes/sends data
- "appleScript": clean AppleScript that executes the command using {{variable}} placeholders
- "inputSchema": JSON Schema with properties for each parameter

Example for Calendar "create event":
{"name": "calendar_create_event", "description": "Create a new calendar event", "app": "Calendar", "strategy": "applescript", "isSensitive": true, "appleScript": "tell application \\"Calendar\\"\\nset newEvent to make new event at end of events with properties {summary:\\"{summary}\\", start date:{startDate}}\\nend tell", "inputSchema": {"type": "object", "properties": {"summary": {"type": "string"}, "startDate": {"type": "string"}}, "required": ["summary", "startDate"]}}

Output ONLY JSON. No explanations, no markdown fences."""
    
    try:
        resp = groq_client.chat.completions.create(
            model=model,
            messages=[
                {"role": "system", "content": "You are an AppleScript compiler. Output only JSON."},
                {"role": "user", "content": prompt}
            ],
            temperature=0.1,
            max_tokens=2000
        )
        text = resp.choices[0].message.content.strip()
        
        # Strip markdown fences if present
        if text.startswith("```"):
            text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        
        return json.loads(text)
    except Exception as e:
        return None

# ─── Main ───
def main():
    parser = argparse.ArgumentParser(description="Evolve macOS app SDEFs into MCP tools")
    parser.add_argument("--groq-key", required=True, help="Your Groq API key")
    parser.add_argument("--app", action="append", help="Only evolve specific app(s)")
    parser.add_argument("--resume", action="store_true", help="Resume from cache")
    parser.add_argument("--model", default="llama-3.3-70b-versatile", help="Groq model name")
    args = parser.parse_args()
    
    from groq import Groq
    client = Groq(api_key=args.groq_key)
    
    # Load or extract SDEFs
    cache = {}
    if args.resume and os.path.exists(CACHE_FILE):
        with open(CACHE_FILE) as f:
            cache = json.load(f)
        all_tools = cache.get("tools", [])
        processed_commands = cache.get("processed", [])
        print(f"Resumed: {len(all_tools)} tools, {len(processed_commands)} commands processed")
    else:
        all_tools = []
        processed_commands = []
    
    # Step 1: Extract
    print("\n=== Step 1: Extracting SDEFs ===")
    apps = extract_sdefs(target_apps=args.app)
    
    # Step 2: Parse
    print(f"\n=== Step 2: Parsing {len(apps)} apps ===")
    app_commands = []
    for app in apps:
        cmds = parse_sdef(app)
        if cmds:
            app_commands.append({"name": app["name"], "commands": cmds})
            print(f"  {app['name']}: {len(cmds)} commands")
    
    total = sum(len(a["commands"]) for a in app_commands)
    print(f"  Total: {total} commands across {len(app_commands)} apps")
    
    # Step 3: Generate
    print(f"\n=== Step 3: Generating tools via Groq ({args.model}) ===")
    completed = len(processed_commands)
    errors = 0
    rate_limit_hits = 0
    
    # Track processed commands for dedup
    processed_set = set(processed_commands)
    
    for app in app_commands:
        for cmd in app["commands"]:
            cmd_key = f"{app['name']}_{cmd['name']}"
            
            if cmd_key in processed_set:
                continue
            
            tool = generate_tool(client, app["name"], cmd, args.model)
            completed += 1
            
            if tool:
                all_tools.append(tool)
                processed_set.add(cmd_key)
                processed_commands.append(cmd_key)
                print(f"  ✅ [{completed}/{total}] {tool['name']}")
                
                # Save cache every 10 tools
                if completed % 10 == 0:
                    with open(CACHE_FILE, "w") as f:
                        json.dump({"tools": all_tools, "processed": list(processed_set)}, f, indent=2)
            elif "429" in str(tool) or "rate" in str(tool).lower():
                rate_limit_hits += 1
                print(f"  ⏸ [{completed}/{total}] Rate limited. Waiting 30s...")
                time.sleep(30)
                # Retry once
                tool = generate_tool(client, app["name"], cmd, args.model)
                if tool:
                    all_tools.append(tool)
                    processed_set.add(cmd_key)
                    processed_commands.append(cmd_key)
                    print(f"  ✅ [{completed}/{total}] {tool['name']} (retry)")
                else:
                    errors += 1
                    print(f"  ❌ [{completed}/{total}] {cmd_key}")
            else:
                errors += 1
                print(f"  ❌ [{completed}/{total}] {cmd_key}")
            
            # Rate limit: 28 req/min for Groq free
            if completed % 28 == 0 and completed < total:
                wait = 10
                print(f"  ⏳ Rate limit pause: {wait}s...")
                time.sleep(wait)
    
    # Save final output
    with open(OUTPUT_FILE, "w") as f:
        json.dump(all_tools, f, indent=2)
    
    # Clean up cache
    if os.path.exists(CACHE_FILE):
        os.remove(CACHE_FILE)
    
    print(f"\n{'='*50}")
    print(f"✅ Done!")
    print(f"  Tools generated: {len(all_tools)}")
    print(f"  Errors: {errors}")
    print(f"  Rate limit hits: {rate_limit_hits}")
    print(f"  Output: {OUTPUT_FILE}")
    print(f"\nImport into your registry:")
    print(f"  python3 import_evolved_tools.py {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
