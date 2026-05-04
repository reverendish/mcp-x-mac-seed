# Evolved Tools — Test Matrix

**Generated:** 2026-05-03 via Groq llama-3.3-70b-versatile
**Imported:** 2026-05-04 into SQLite registry
**Total:** 313 tools across 27 apps
**Legend:** [ ] Untested | [✅] Working | [❌] Failed (needs Repairman) | [⏸️] Consent-gated | [🔒] Marked sensitive

---

## Engine Status (2026-05-04)

✅ **SDEF-aware execution** — Engine auto-extracts app SDEFs on first use, fuzzy-matches tool names to SDEF commands
✅ **Auto-launch** — `open -a` launches closed apps before scripting (fixes -600 errors)
✅ **Confidence ≥ 90%** — Only exact matches (1.0) and space-normalized (0.95) SDEF matches are used
✅ **Strategy order** — AppleScript (primary) → AppIntent (fallback) → Accessibility (last resort)
✅ **Name normalization** — `music_next_track` → `next track` via SDEF matching
✅ **close→quit heuristic** — `music_close` → `tell app "Music" to quit`

**Tested:** 48/313 tools (15%)

---

## Already Tested

| App | Tool | Result | Notes |
|-----|------|--------|-------|
| **Finder** | activate | ✅ | Hardcoded |
| Finder | open | ✅ | Hardcoded |
| Finder | close | ❌ | Needs target (window) |
| Finder | count | ❌ | Needs "count of every" |
| Finder | copy | ❌ | Ambiguous reference |
| **Calendar** | show | ✅ | SDEF: auto-launch |
| Calendar | reload_calendars | ✅ | SDEF: auto-launch + match |
| Calendar | view_calendar | ❌ | SDEF exists but syntax fails |
| Calendar | geturl | ❌ | SDEF exists but syntax fails |
| Calendar | switch_view | ❌ | SDEF exists but syntax fails |
| Calendar | create_calendar | ⏸️ | Consent gate |
| Calendar | calendar_make | ⏸️ | Consent gate |
| Calendar | calendar_save | ⏸️ | Consent gate |
| **Music** | play | ✅ | Native verb |
| Music | pause | ✅ | Native verb |
| Music | playpause | ✅ | Native verb |
| Music | next_track | ✅ | SDEF: "next track" |
| Music | previous_track | ✅ | SDEF: "previous track" |
| Music | fast_forward | ✅ | SDEF: "fast forward" |
| Music | back_track | ✅ | SDEF: "back track" |
| Music | rewind | ✅ | SDEF: "rewind" |
| Music | resume | ✅ | SDEF: "resume" |
| Music | stop | ⏸️ | Consent gate |
| Music | close | ❌ | SDEF has close/quit, match works, runtime fails |
| **QuickTime Player** | play | ✅ | Auto-launch |
| QuickTime Player | pause | ✅ | Auto-launch |
| QuickTime Player | start | ✅ | Auto-launch |
| QuickTime Player | step_forward | ✅ | Auto-launch |
| QuickTime Player | stop | ⏸️ | Consent gate |
| **VLC** | open | ✅ | Auto-launch |
| VLC | mute | ✅ | Auto-launch |
| VLC | next | ✅ | Auto-launch |
| VLC | fullscreen | ✅ | Auto-launch |
| VLC | play | ❌ | App not running (needs separate VLC-specific launch) |
| **Reminders** | show | ✅ | Hardcoded |
| Reminders | make | ⏸️ | Consent gate |
| **Notes** | show | ✅ | Works |
| **System Settings** | reveal | ✅ | Works |
| **Safari** | search_the_web | ❌ | SDEF mismatch |
| Safari | show_bookmarks | ❌ | SDEF mismatch |
| Safari | show_privacy_report | ❌ | SDEF mismatch |
| Safari | show_extensions_preferences | ❌ | SDEF mismatch |
| Safari | do_javascript | ❌ | SDEF mismatch |
| **TextEdit** | open | ❌ | No SDEF (not scriptable) |
| **Photos** | open | ❌ | No SDEF for open |
| **Spotify** | play | ❌ | No SDEF (Electron app) |
| **Google Chrome** | open | ❌ | No SDEF (needs UI automation) |
| **Preview** | open | ❌ | No SDEF for open |
| **Terminal** | do_script | ❌ | App not running |

## Summary

| Status | Count | Apps |
|--------|-------|------|
| ✅ Working (auto-launch + SDEF) | 22 | Music, Calendar, VLC, QuickTime, Finder |
| ⏸️ Consent-gated | 5 | Calendar, Music, QuickTime, Reminders |
| ❌ Failed (needs Repairman) | 21 | Safari, TextEdit, Photos, Spotify, Chrome, Preview, etc. |
| [ ] Untested | 265 | Remaining 25 apps |

**Running total:** 48/313 tested = 15%

**Apps that work well:** Music (11/28 working), QuickTime Player (4/14), VLC (4/30), Calendar (2/8)
**Apps needing Repairman:** Safari (5), Finder (3), Mail (19 untested)
**Apps that need Accessibility fallback:** Spotify, Google Chrome (no SDEF)
