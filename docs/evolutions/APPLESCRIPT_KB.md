# AppleScript Knowledge Base — MCP-x-Mac-Seed

**Purpose:** Shared learning document for the batch evolution pipeline, Repairman loop,
and SDEF-aware execution engine. Updated after every test and repair session.

**Last updated:** 2026-05-04 (batch repair: 239 tools auto-repaired)

---

## Core Principles

1. **SDEF is the source of truth.** Command names, parameter structures, and types all
   come from each app's scripting dictionary (`/usr/bin/sdef`). Never guess.

2. **Tool names use underscores.** SDEF commands use spaces. The engine normalizes
   `music_next_track` → `next track` via SDEF fuzzy matching.

3. **Apps need to be running.** The engine auto-launches via `open -a` but some apps
   (Mail with accounts, TV with sign-in) need additional setup.

4. **Test results teach the system.** Every pass/fail updates this doc. The Repairman
   and `batch_repair.py` both read from here.

---

## Name Normalization Table

The batch pipeline generates tool names from `{app}_{command}`. The SDEF-aware engine
normalizes these to actual AppleScript command names:

| Generated Name | SDEF Command | Method |
|---------------|-------------|--------|
| `music_next_track` | `next track` | Space-normalized (conf 0.95) |
| `music_previous_track` | `previous track` | Space-normalized |
| `music_fast_forward` | `fast forward` | Space-normalized |
| `music_back_track` | `back track` | Space-normalized |
| `calendar_reload_calendars` | `reload calendars` | Space-normalized |
| `calendar_switch_view` | `switch view` | Space-normalized |
| `calendar_view_calendar` | `view calendar` | Space-normalized |
| `safari_search_the_web` | `search the web` | Space-normalized |
| `safari_show_bookmarks` | `show bookmarks` | Space-normalized |
| `safari_do_javascript` | `do JavaScript` | Space-normalized |
| `*_close` | `quit` (apps) / `close window 1` (Finder, Preview, TextEdit) | Heuristic |
| `*_make` | `make new X` (needs type from SDEF) | Parameter structure |

---

## AppleScript Recipes by App

### Music.app ✅ Highly Scriptable

```applescript
# Direct verbs (Type A)
tell application "Music" to play
tell application "Music" to pause
tell application "Music" to playpause
tell application "Music" to quit
tell application "Music" to activate

# SDEF commands (space-normalized from tool names)
tell application "Music" to next track          # music_next_track
tell application "Music" to previous track      # music_previous_track
tell application "Music" to fast forward        # music_fast_forward
tell application "Music" to back track          # music_back_track
tell application "Music" to rewind              # music_rewind
tell application "Music" to resume              # music_resume

# Complex commands
tell application "Music" to add "{file}" to playlist "{playlist}"
tell application "Music" to search for "{query}"
tell application "Music" to play track "{name}"
```

**Verified working (12/28):** play, pause, playpause, quit, next_track, previous_track,
fast_forward, back_track, rewind, resume, stop (consent-gated)

### Calendar.app

```applescript
# Activate (always works)
tell application "Calendar" to activate

# SDEF-specific commands (Type B — need parameter structure)
tell application "Calendar" to reload calendars                                    # No params
tell application "Calendar" to switch view to week view                           # param: to
tell application "Calendar" to view calendar at date "5/5/2026"                  # param: at
tell application "Calendar" to GetURL "webcal://example.ics"                     # direct param
tell application "Calendar" to show item_name                                    # direct param
tell application "Calendar" to save                                               # consent-gated
```

**Verified working (4/8):** show, reload_calendars, switch_view, geturl
**Failing:** view_calendar (date format), create_calendar (consent), make (consent), save (consent)

### Safari.app

```applescript
tell application "Safari" to show bookmarks
tell application "Safari" to show privacy report
tell application "Safari" to show extensions preferences
tell application "Safari" to search the web for "{query}"
tell application "Safari" to do JavaScript "{code}" in current tab of front window
  ⚠️ Requires: Safari → Settings → Advanced → "Show Develop menu" → Develop → "Allow JavaScript from Apple Events"
```

**Verified working (4/10):** show_bookmarks, search_the_web, show_privacy_report, show_extensions_preferences
**Failing:** do_javascript (needs Safari dev setting)

### Finder.app

```applescript
tell application "Finder" to activate
tell application "Finder" to open POSIX file "/path"
tell application "Finder" to close front window
tell application "Finder" to return count of every item of folder (POSIX file "/path")
tell application "Finder" to copy file (POSIX file "/src") to folder (POSIX file "/dst")
tell application "Finder" to select POSIX file "/path"
tell application "Finder" to make new folder at desktop with properties {name:"New Folder"}
```

**Verified working (4/25):** activate, open, close (repaired), count (repaired)
**Not yet tested:** copy, select, new_folder, move, delete, duplicate, eject, empty, erase, restart, shut_down, sleep, sort, update

### Mail.app

```applescript
# Hardcoded in ExecutionEngine (Tier 1)
tell application "Mail" to check for new mail                              # mail_check_for_new_mail
tell application "Mail" to check for new mail for account "{account}"     # with account
tell application "Mail" to synchronize with account "{account}"           # mail_synchronize
tell application "Mail" to return count of every message of inbox         # mail_count

# Complex (hardcoded builders)
tell application "Mail" to send email (buildMailSend)                     # mail_send 🔒
tell application "Mail" to reply to email (buildMailReply)                # mail_reply 🔒
tell application "Mail" to forward email (buildMailForward)               # mail_forward 🔒
tell application "Mail" to get messages (buildMailGetMessages)            # mail_get_messages

# SDEF commands (need Mail.app configured with an account)
mail_bounce, mail_redirect, mail_mailto, mail_geturl,
mail_perform_mail_action_with_messages, mail_extract_name_from,
mail_extract_address_from, mail_import_mail_mailbox
```

⚠️ Mail.app needs at least one configured email account for most commands.

### QuickTime Player.app

```applescript
tell application "QuickTime Player" to play
tell application "QuickTime Player" to pause
tell application "QuickTime Player" to start
tell application "QuickTime Player" to step forward
tell application "QuickTime Player" to step backward
tell application "QuickTime Player" to resume
tell application "QuickTime Player" to stop             🔒 consent-gated
tell application "QuickTime Player" to trim              # needs selection
tell application "QuickTime Player" to export            🔒 consent
tell application "QuickTime Player" to new movie recording
tell application "QuickTime Player" to new audio recording
tell application "QuickTime Player" to new screen recording
```

**Verified working (5/14):** play, pause, start, step_forward, resume

### VLC.app

```applescript
tell application "VLC" to play
tell application "VLC" to pause
tell application "VLC" to stop                🔒 consent
tell application "VLC" to next
tell application "VLC" to previous
tell application "VLC" to fullscreen
tell application "VLC" to mute
tell application "VLC" to volumeUp
tell application "VLC" to volumeDown
tell application "VLC" to stepForward
tell application "VLC" to stepBackward
tell application "VLC" to OpenURL "{url}"
```

**Verified working (5/30):** open, mute, next, fullscreen, previous

### Reminders.app

```applescript
tell application "Reminders" to activate                              # reminders_show
tell application "Reminders" to make new reminder with properties {name:"{name}"}  # reminders_make 🔒
```

**Verified working (1/2):** show
**Consent-gated:** make

### Notes.app

```applescript
tell application "Notes" to activate                                  # notes_show
tell application "Notes" to show note "{title}"                      # notes_open_note_location
```

**Verified working (2/2):** show, open_note_location

### System Settings.app

```applescript
tell application "System Settings" to activate
# reveal pane: not directly scriptable via SDEF — uses URL scheme
open "x-apple.systempreferences:com.apple.preference.security"
```

### System Events.app

```applescript
tell application "System Events"
    tell process "Finder"
        click button "{name}"
        keystroke "{text}"
        key code {number}
    end tell
end tell
```

### Terminal.app

```applescript
tell application "Terminal"
    do script "{command}" in front window
    activate
end tell
```

⚠️ Terminal needs a window to exist before `do script` works.

---

## Command Type Classification

### Type A: Direct App Verbs
These apps respond to `tell app "X" to verb` syntax:
- **Music:** play, pause, playpause, quit, next track, previous track, etc.
- **QuickTime Player:** play, pause, stop, start, step forward/backward
- **VLC:** play, pause, stop, next, previous, fullscreen, mute

### Type B: SDEF-Routed Commands
These apps require specific SDEF syntax with parameters:
- **Calendar:** reload calendars, switch view, view calendar, GetURL
- **Safari:** search the web, show bookmarks, do JavaScript, email contents
- **Mail:** check for new mail, bounce, redirect, mailto
- **Finder:** count of every item, copy file to folder, sort by
- **Notes:** show note, make new note
- **Reminders:** make new reminder with properties

### Type C: Accessibility-Only (No SDEF)
Apps without scripting dictionaries — needs UI automation:
- Google Chrome / Chromium-based
- Spotify (Electron)
- VS Code / Cursor / Copilot
- Discord
- Slack
- Figma

---

## Pitfalls & Known Issues

### 1. App Not Running (-600)
**Symptom:** `Application isn't running. (-600)`
**Fix:** Engine now auto-launches via `open -a <app>` with 2s wait. But some apps
(Mail, TV) need additional configuration before AppleScript works.
**KB entry:** Auto-launch added 2026-05-04.

### 2. Safari JavaScript Blocked
**Symptom:** `You must enable 'Allow JavaScript from Apple Events'`
**Fix:** User must enable: Safari → Settings → Advanced → Show Develop menu →
Develop → Allow JavaScript from Apple Events.
**KB entry:** 2026-05-04 — cannot be automated.

### 3. Mail Needs Account
**Symptom:** Commands like `check for new mail` silently fail or return empty.
**Fix:** At least one email account must be configured in Mail.app.

### 4. Underscore vs Space Mismatch
**Symptom:** `tell app "Music" to next_track` fails, `next track` works.
**Fix:** ExecutionEngine now does space-normalized SDEF matching (conf 0.95).
**KB entry:** Fixed 2026-05-04.

### 5. Close vs Quit Ambiguity
**Symptom:** `tell app "Music" to close` fails (needs window target).
**Fix:** Close → quit heuristic for non-window apps. Window apps (Finder, Preview,
TextEdit, Pages, Numbers, Keynote) use `close window 1`.
**KB entry:** Fixed 2026-05-04.

### 6. Date Format Sensitivity
**Symptom:** `view calendar at date "May 5, 2026"` fails.
**Fix:** Use `"5/5/2026"` format for Calendar dates.
**KB entry:** 2026-05-04.

### 7. Terminal Needs Existing Window
**Symptom:** `do script "cmd"` fails when Terminal has no window.
**Fix:** Auto-launch Terminal then `make new window` before `do script`.

### 8. Consent-Gated Commands Never Auto-Execute
**Symptom:** Sensitive tools (delete, send, make, save) always return PENDING.
**Fix:** This is by design. User must approve via `request_human_approval`.

---

## Test Results History

### 2026-05-04 — Batch Repair: 239 tools auto-repaired

Batch script matched 239 of 313 tools to their SDEF commands and generated correct
AppleScript. 74 tools couldn't match (SDEF command name mismatch or ambiguous).

**Post-repair test results:**
- ✅ QuickTime: resume — works
- ✅ Notes: open_note_location — works
- ✅ VLC: previous — works
- ❌ Music: open — app not running (Music was closed)
- ❌ Mail: check_for_new_mail — needs account
- ❌ TV: play — needs sign-in
- ⏸️ Mail: send — consent-gated

### 2026-05-04 — SDEF-aware engine + auto-launch: 22/48 working

See APPLESCRIPT_KB.md history section for detailed test matrix.

### 2026-05-04 — Initial import: 12/313 working, 8 app-not-running

See TEST_MATRIX.md for detailed log.

---

## Repairman Guidelines

When repairing a failed tool:

1. **Read this KB** — check if app has known patterns
2. **Fetch SDEF:** `fetch_scripting_dictionary(appName)`
3. **Check raw SDEF XML:** `/usr/bin/sdef <path>` for exact parameter structure
4. **Match tool name to SDEF command** (space-normalized, close→quit)
5. **Generate AppleScript** with correct parameter placeholders (`{paramName}`)
6. **Register corrected tool:** `register_tool` with `appleScript` field
7. **Test execution:** `execute_intent` with sample parameters
8. **Update this KB** with any new pattern or pitfall found

## Batch Generation Guidelines

When the batch pipeline (evolve_mac_apps.py, batch_repair.py) generates tools:

1. **Extract exact SDEF command names** — no normalization
2. **Match tool names via space-normalized fuzzy match**
3. **Generate AppleScript using SDEF parameter structure:**
   - Direct parameters: `cmd "{value}"`
   - Named parameters: `cmd paramName:"{paramName}"`
   - No-param commands: `cmd` (plain)
4. **Set `isSensitive` for:** delete, send, make, save, create, export, shut_down, restart
5. **Set `requiresApproval` matching isSensitive**
6. **Read this KB** to avoid known anti-patterns
7. **After repair, update this KB** with any new learnings
