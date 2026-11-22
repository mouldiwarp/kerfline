# Roadmap

Status key: ✅ done · 🚧 in progress · ⬜ planned · 💡 idea

## Milestones

| # | Milestone | Status |
|---|---|---|
| 1 | Scaffold: monorepo, README, roadmap, CI | ✅ |
| 2 | Shared library and GRBL simulator | ✅ |
| 3 | Agent: serial streamer, machine state, job control | ✅ |
| 4 | Hub: library, upload API, inbox, Bonjour, sync | ✅ |
| 5 | Web UI: DRO, jog, zero, 3D progress, library, console, overrides, macros | ✅ |
| 6 | Sync hardening: restart mid-job, multi-browser tests, double-click launchers, setup guide | ✅ |
| 6b | Mac app launched from Spotlight (hub / agent / simulator roles; quitting stops the server) | ✅ |
| 7 | "Send to GRBL Controller" in Swarf and Fretboard Modeller | ✅ merged into main in both apps |
| 7b | Z probe with a touch plate; run a file group in order with bit-change stops | ✅ (simulator-tested; check on the machine) |
| 7c | Library manager: project folders in `~/Documents/GCode Controller`, kept in step with Finder | ✅ |
| 7d | Version checks: an out-of-date agent is held until it's updated, with Update now | ✅ |
| 7e | Spoilboard surfacing: zero at the left edge on the centre line, ramp-in zigzag skim | ✅ (simulator-tested) |
| 8 | Real machine bring-up (FoxAlien XE-Pro Ultra) | ✅ homing, probing, spindle and surfacing on the machine |
| 9 | **1.0** (tag `v1.0`): pause/resume, time-based progress, travel limits, start-up settings check | ✅ |

## 2.0: one native Swift app

2.0 replaced 1.0 on 18 Nov 2026. It's a single app that asks on first launch
whether this Mac is the hub or the agent. Either Mac can drive the FoxAlien over USB, and the
library is kept fully in sync on both Macs, with conflicts resolved by asking. There's no browser.
The code is in `swift/`. Try the machine layer from the command line:

```sh
cd swift
swift run gcc ports                                   # serial ports (* = looks like GRBL)
swift run gcc stream --simulate ../samples/test-square.nc
swift run gcc stream ../samples/test-square.nc        # USB, port auto-detected (or --port PATH)
```

`gcc stream` prints the console and progress, and Ctrl-C stops the job (feed hold, then reset).

Install the app on each Mac with `scripts/build-app.sh` (about a minute; it installs
"GCode Controller 2.0" in `~/Applications`, and adds no login item). After that it
updates itself: it checks GitHub every few hours (or GCode Controller 2.0 ▸ Check for Updates…),
and **Update now** pulls, rebuilds and restarts it. Either Mac can ask the other to update when it's
behind. Neither updates while a job runs on it. While a Mac has the machine on USB it's kept awake.

| Phase | What | Status |
|---|---|---|
| 1 | Core: G-code, GRBL protocol, state and commands, resume, progress, travel, surfacing, settings check (ported and checked identical to 1.0) | ✅ |
| 2 | Machine: serial port, simulator, streaming session (1.0's controller tests all ported), `gcc` command-line streamer. Real-machine air cut with `gcc stream` still to do | ✅ |
| 3 | Library on disk: content blobs, SQLite with a per-field change log, Finder folder kept in step both ways (moves keep their id), 5 versions / 30 days of history, a 30-day Trash, 1.0 import | ✅ |
| 4 | Network and sync: hub API (Swarf/Fretboard unchanged), Bonjour, inbox, link between the Macs with either-Mac machine ownership and command relay, library sync and conflicts (log compaction deferred) | ✅ |
| 5 | App shell: role picker (with a trial mode that leaves 1.0 alone), main window with every panel except 3D, keyboard jog, menus, toasts, library manager (folders, version history, Trash), conflict badges and dialog. Agent-alone-when-hub-is-down not yet tried on two Macs | ✅ |
| 6 | Metal 3D view and every dialog | ✅ |
| 7 | Build, install and self-update: `scripts/build-app.sh`, update from git (either Mac can update the other), keep-awake while it owns the machine | ✅ |
| 8 | Cut-over: both Macs run 2.0 (two-Mac rehearsal with the simulator, then on the FoxAlien: home, settings check, probe, surfacing, pause/resume, stop and resume from a line, self-update). 1.0's code removed (it's at tag `v1.0`). Tagged **v2.0** | ✅ |
| 9 | Signed releases: Developer ID signing, the app's final name, release builds on GitHub, updates from Releases (see below) | ⬜ waiting for the Apple Developer membership |

### Phase 9: signed releases
- ✅ **Name** agreed: **KerfLine**, "a GRBL sender built for the FoxAlien XE-Ultra 8080 and other GRBL 1.1 machines",
  with a line saying it isn't affiliated with or endorsed by FoxAlien. No FoxAlien logo, colours or "official".
- ✅ The window, top bar and messages already say KerfLine.
- ✅ Repo and docs renamed (`mouldiwarp/kerfline`). Releases are **KerfLine** (`io.github.mouldiwarp.kerfline`) and
  bring over the GCode Controller 2.0 settings on first launch; builds from git keep the old name until the Macs move.
- ✅ **Developer ID signing** in `scripts/build-app.sh` (hardened runtime, timestamp, Sparkle signed inside out),
  falling back to ad-hoc without the certificate.
- ✅ **Release workflow** (`.github/workflows/release.yml`, `scripts/release.sh`): a `vX.Y` tag builds the universal
  app on the macOS 26 runner, signs, notarizes and staples it, and makes a GitHub Release with the `.dmg`, `.zip` and
  appcast. Unsigned or un-notarized builds stay drafts. See [docs/RELEASING.md](docs/RELEASING.md).
- ✅ **Updates from Releases** with Sparkle 2, driven by the app's own update banner: either Mac can tell the other to
  update, never mid-job, and "behind" means an older version. Tested end to end with a local feed (ad-hoc signed).
- ✅ The build-from-git updater stays for builds from the checkout.
- ⬜ **Apple Developer membership** (applied 2026-11-18), then set the secrets (docs/RELEASING.md) and tag the first
  release. Check it opens on a fresh Mac with no Gatekeeper warning, and that the relaunch after an update works.
- ⬜ Move both Macs to the KerfLine release; the website links to the download.
- ⬜ Later: rename the library folder and the `gcc.*`/Bonjour names to KerfLine (needs a migration on both Macs).

## Next up

### Machine bring-up (when the machine arrives)
- ⬜ Confirm the firmware with `$I` (GRBL 1.1 or a FoxAlien variant) and the RX buffer size it reports.
- ⬜ Read `$$` and set the machine travel from `$130`–`$132` (there's a **Read from GRBL** button in Settings).
- ⬜ Confirm the homing corner (`$23`) and draw the envelope in the right place. Today the envelope assumes
  GRBL's default (machine 0,0,0 at back-right-top).
- ⬜ Check spindle control: `M3 S…` against `$30`/`$31` with the 1.5 kW VFD.
- ⬜ Test Probe Z on the real plate: the probe pin (`Pn:P`) lights when the plate touches the bit, and a
  probe that misses raises ALARM 5.
- ⬜ First air cut of `samples/test-square.nc` with Z zeroed 20 mm above the stock.

### Workflow features (from UGS and WorkBee)
- ✅ **Progress by time, not lines.** The % and time left follow the line the machine is cutting (not the
  lines GRBL has queued), weighted by each line's estimated time and how far along it the tool is.
- ✅ **Z probe with a touch plate** (`G38.2`): a fast touch then a slow one, with plate thickness in Settings.
- ✅ **Run a job group in order**, stopping for a bit change and a Z re-probe between files.
- ⬜ Probe X/Y corners with the touch plate (corner-finding), as WorkBee's XYZ probe block does.
- ⬜ Remember the probe result per group, and warn on Start next if Z wasn't re-probed after the bit change.
- ⬜ **Continuous jog:** hold a button or key to jog, release to stop (`$J=` plus jog cancel).
- ✅ **Resume from line N** after a stop, with a safe preamble (modes, safe Z, XY, spindle on and spin-up, then down). Defaults to the line the cutter was on. Spindle stop/start while held. **Pause** stops at the current line and raises Z to the top (GRBL can't move in a feed hold, and the FoxAlien's firmware has no parking); Resume carries on from that line.
- ⬜ **Check mode** (`$C`) dry run, which streams the file through GRBL's parser without moving, to catch
  errors before cutting.
- ⬜ **Block a start** when the toolpath goes outside the machine travel. Today the UI only warns.
- ⬜ **Settings editor:** change `$` settings from the table instead of typing them in the console.

### Visualizer
- ⬜ Track the executing line exactly by adding `N` line numbers and reading `Ln:` from status reports.
  Today it's estimated from acknowledged lines minus the planner queue.
- ⬜ Depth-aware drawing. Later passes over the same XY at a lower Z draw over cut segments, which hides
  some of the gold. Draw finished segments on top, or add a "hide below current Z" slider.
- ⬜ Check that very large files (3D finishing passes run to 1M+ lines) parse off the main thread without the UI stuttering.
- 💡 Stock box and simulated material removal, like Swarf's simulation.

### Comfort and safety
- ✅ Home X, Y or Z on its own (`$HX`… where the firmware has it, else back to the last full home's position).
- ✅ **Go to XYZ0** asks first, naming where the file expects Z zero (spoilboard or top of the material).
- ⬜ macOS notification and sound when a job finishes, pauses on an error or alarms.
- ⬜ Touch-friendly "garage mode": bigger buttons, full screen, wake lock so the display stays on.
- ⬜ Job history: what ran, when, how long, who started it, and how it ended.
- ✅ Warn when hub and agent versions differ (2.0's update banner).
- 💡 Optional PIN for starting jobs, in case other people use the home network.
- 💡 Webcam view of the machine in the UI.
- 💡 Height-map probing and auto-levelling for engraving on uneven stock.

### Engineering
- ⬜ A UI test that drives both apps (today the two-Mac flows are covered by in-process link tests and the rehearsal).
- ⬜ Show machine and job status in the Mac app's window and Dock icon (progress badge, alarm colour).
