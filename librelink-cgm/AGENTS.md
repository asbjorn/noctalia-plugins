# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-27
**Plugin ID:** `librelink-cgm`

## OVERVIEW
Noctalia QML plugin that polls the LibreLinkUp cloud API for CGM glucose readings, persists history to a local SQLite DB, and renders a bar widget + expandable panel with a live glucose chart.

## STRUCTURE
```
librelink-gcm/          # Distributable snapshot (same files + README.md + p1.png) — DO NOT edit here; edit root files
Main.qml                # Logic layer: auth, API polling, DB management, data model
BarWidget.qml           # Bar: compact glucose + trend arrow, pulses when stale
Panel.qml               # Expanded panel: Canvas chart, hover tooltip, time-window buttons
Settings.qml            # Settings UI: email, password (keyring), region, thresholds
manifest.json           # Plugin metadata + entryPoints + defaultSettings
settings.json           # Runtime state (written by Noctalia) — contains live patientId
```

## WHERE TO LOOK
| Task | Location |
|------|----------|
| API call logic / auth flow | `Main.qml` → `authenticate()`, `fetchConnections()`, `fetchGraphData()` |
| Account ID hashing | `Main.qml` → `hashAccountIdProcess` (SHA256 via `sha256sum`) |
| Password read/write | `Main.qml` → `lookupPasswordProcess` / `storePasswordProcess` (secret-tool) |
| SQLite DB init + schema | `Main.qml` → `ensureDbDirProcess` → `initDbProcess` |
| DB insert / query / prune | `Main.qml` → `insertProcess`, `queryProcess`, `pruneProcess` |
| Chart rendering | `Panel.qml` → `Canvas { id: chart }` + `onPaint` handler |
| Unit conversion (mg/dL ↔ mmol/L) | `Main.qml::formatBG()`, `Panel.qml::formatBG()` |
| Stale data detection | `Main.qml::isStale` (readonly property) |
| Suspend/resume handling | `Main.qml::onSystemResume()` + `suspendWatcher` Process (dbus-monitor) |
| Threshold alerting | `Main.qml::checkThresholdAlert()` → `ToastService.showWarning()` |
| Plugin API surface | `pluginApi.mainInstance`, `pluginApi.pluginSettings`, `pluginApi.saveSettings()` |

## ARCHITECTURE

**Main.qml is the singleton logic layer.** UI files (`BarWidget`, `Panel`, `Settings`) are purely display — they receive `pluginApi` injected by Noctalia and access state via `pluginApi.mainInstance`.

**All async operations use `Process {}` + `SplitParser`** (Quickshell's subprocess API) — no promises, no callbacks outside `onRunningChanged`. Never use synchronous subprocess calls.

**Poll cycle:** `Timer (interval: 60s)` → `fetchGraphData()` → on 401/403 re-authenticates → on success `updateFromGraphPayload()` → `insertReadingsToDb()` → `loadHistoryFromDb()` → `historyRevision++` → Canvas `requestPaint()`.

## CONVENTIONS

**Internal values always `mg/dL` integers.** `sgv` field in `historyModel` and DB is always mg/dL. Convert to mmol/L only at display time via `formatBG()`.

**Thresholds (`lowThreshold`, `highThreshold`) are always stored in mg/dL** regardless of the user's selected display units.

**Private properties prefixed `_`** (e.g., `_password`, `_requestInFlight`, `_dbReady`). Do not expose or persist these.

**`historyRevision`** is a monotonic integer incremented after every DB load. Chart uses it as a `Connections` trigger to repaint.

**`Chart.markDirty()` + `requestPaint()` must be called together** when forcing a Canvas repaint from an external source.

## ANTI-PATTERNS (THIS PROJECT)

- **NEVER persist `_password` to `settings.json`** — password lives exclusively in the OS keyring via `secret-tool`.
- **NEVER send raw user ID from login response** — must be SHA256-hashed first (see `hashAccountIdProcess`).
- **NEVER store patientId discovered from the API anywhere other than `settings.json`** — it is persisted via `persistSetting("patientId", ...)`.
- **NEVER edit files in `librelink-gcm/` subdir** — it is a distributable snapshot; only root-level files are active.
- **NEVER call a new `Process.running = true` while `_requestInFlight`, `_storeInProgress`, or `_hashInProgress` is true** — guard with these flags.
- **Threshold labels in Settings are always `(mg/dL)`** even when units display is mmol/L; conversion is display-only.

## UNIQUE STYLES

- LibreLink API requires spoofed iOS User-Agent headers (`llu.ios` product, version `4.16.0`) — see `applyCommonHeaders()`.
- LibreLink timestamp format is `M/D/YYYY h:mm:ss AM/PM` — `normalizeIso()` handles the conversion to ISO 8601.
- API envelope: `{ status: 0, data: ... }` — `parseEnvelope()` validates and unwraps. Any `status !== 0` is an error.
- DB path: `~/.cache/noctalia/plugins/librelink-cgm/readings.db` (never hardcoded, resolved via `$HOME`).
- Alert cooldown: 5 min (`_alertCooldownMs: 300000`).

## COMMANDS
```bash
# No build step — QML files are loaded directly by Noctalia.
# Reload the plugin in Noctalia after editing (no hot-reload by default).

# Inspect the SQLite DB:
sqlite3 ~/.cache/noctalia/plugins/librelink-cgm/readings.db "SELECT * FROM readings ORDER BY timestamp DESC LIMIT 20;"

# Check/set keyring password:
secret-tool lookup application librelink-cgm type password
printf '%s' "yourpassword" | secret-tool store --label "LibreLink CGM" application librelink-cgm type password
```

## NOTES
- `settings.json` at the root is the live runtime file written by Noctalia — it may contain a `patientId` from a previous session.
- The `librelink-gcm/` subdir mirrors root files and is the distributable package; `p1.png` is a screenshot for the README only.
- Region URL map is hardcoded in `Main.qml::_regionUrls`; add new regions there if LibreLink expands.
- DB prunes readings older than 30 days and any rows with non-ISO timestamps on every startup.
