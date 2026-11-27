# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

SwarfGRBL is a native macOS GRBL sender (Swift 6.2, macOS 26, SwiftUI + Metal) for a FoxAlien XE-Ultra CNC. The same app
runs on two Macs: a **Hub** (design Mac) and an **Agent** (garage Mac next to the machine). It moves a real machine with a
spinning cutter, so treat streaming, travel checks, hold/stop and resume logic as safety-critical.

## Commands

All Swift code is one package in `swift/`.

```sh
scripts/ci.sh                    # what GitHub CI runs (swift test), in a clean worktree of HEAD — use this instead of waiting on CI
CI_DIRTY=1 scripts/ci.sh         # same, against the working tree (faster; misses uncommitted files)
cd swift && swift test           # all tests
swift test --filter SGCoreTests                      # one test target
swift test --filter "SGLibraryTests.SyncTests"       # one suite (swift-testing; filter by suite/test name)
swift run SwarfGRBL        # run the app without installing
swift run swarfgrbl-cli ports              # list serial ports (* = looks like GRBL)
swift run swarfgrbl-cli stream --simulate ../samples/test-square.nc   # stream to the built-in GRBL simulator
scripts/build-app.sh             # build from git: SwarfGRBL.app, installed to ~/Applications
scripts/release.sh 2.1           # a SwarfGRBL release in dist/ (universal app, dmg, zip, appcast); CI runs it on a v* tag
```

By default `scripts/ci.sh` tests `HEAD`, so commit before relying on it.

Tests use **swift-testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest.
`SG_SNAPSHOT_DIR=<dir>` makes `DialogSnapshotTests` write each dialog as a PNG for checking layout offscreen.

### Dev runs beside the installed app

`SG_HOME=<folder> swift run SwarfGRBL` puts the saved setup, library, data and inbox under that folder, on port
8090 and Bonjour `_swarfgrbl-dev._tcp`, so it doesn't touch the real install (`SGUI/Setup.swift`). Only in that mode:
`SG_SELECT=<file name>` / `SG_OPEN=probe|resume|surfacing|settings|start` open a dialog at launch, and a distributed
notification `swarfgrbl.dev.show` opens dialogs/sheets from a script, or switches to the simulator and back (`simulator`,
`machine`) (see `DevShow` in `SGUI/App.swift`).

## Architecture

Module layering (each depends only on those above it; see `swift/Package.swift`):

- **SGCore** — pure Swift, no I/O. G-code parsing, GRBL protocol/replies, the shared `AppState`/`Command` types
  (`Protocol.swift`, JSON shapes kept compatible with 1.0's saved data), resume-from-line, progress/time estimates,
  travel-limit checks, surfacing program generation, and the expected-`$$` settings check (`MachineCheck.swift`).
- **SGMachine** — `Transport` (USB `SerialPort` or `FakeGrbl` simulator) and `MachineSession`, an actor that streams
  jobs with GRBL's character-counting protocol (unacked bytes never exceed the RX buffer) and emits `SessionEvent`s.
- **SGLibrary** — the library on disk: content-addressed `BlobStore`, SQLite with a per-field change log, the Finder
  folder (`~/Documents/SwarfGRBL`) kept in step both ways by `WorkingCopy`/`FolderWatcher`, history, Trash,
  1.0 import. `Sync.swift` holds the sync rules: version vectors, stamps with a base; conflicting `path`/`content`
  edits become user-resolved conflicts, most other fields are newest-wins.
- **SGNet** — `Instance` is the whole running app minus the window. Hub: Hummingbird HTTP API (`POST /api/jobs` for
  SwarfPath/Fretboard, localhost-only `POST /api/command`), Bonjour `_swarfgrbl._tcp`, inbox watcher, and the `/link`
  WebSocket. Agent: dials the hub's `/link` (Bonjour or explicit URL) and keeps redialling. `LinkMessage.swift` defines
  the link protocol (`hello`, `snapshot`, `cmd`/`result`, `toast`, `sync`; bump `linkProtocolVersion` on breaking changes).
- **SGUI** — `AppModel` (window state; every button goes through `run(Command)`, refusals become toasts), SwiftUI
  panels and `Dialogs/`, the Metal toolpath view in `Viz/`, and `Updater` (self-update from the git checkout).
- Executables: `SwarfGRBL` (the app, just calls `SwarfGRBLApp.main()`) and `swarfgrbl-cli` (headless CLI sender).

Key behaviours that span modules:

- **Machine ownership**: whichever Mac has the controller on USB owns it and is authoritative for machine/job/console
  state; the other mirrors snapshots and relays commands over the link. Either role (hub or agent) can own it.
- **Jobs stream from the owning Mac's own copy** of the library, never over the network, so Wi-Fi drops can't starve
  the machine. File groups are copied over before the first file starts.
- **Both Macs hold a full library replica**; `LibrarySync` exchanges change logs whenever linked.
- **Self-update**, two ways, both driving the same update banner and never installing while a job runs on that Mac:
  - Builds from git: `build-app.sh` bakes `SGRepoPath`/`SGCommit`/`SGCommitTime` into Info.plist; the app pulls and
    rebuilds that checkout, and refuses if it's dirty (`Updater.swift`).
  - Releases (`SG_RELEASE=1`, Info.plist has `SUFeedURL`): Sparkle 2 with a custom user driver
    (`ReleaseUpdater.swift`), feed `releases/latest/download/appcast.xml`, EdDSA public key in
    `scripts/sparkle-public-key.txt`. Publishing, secrets and the website links: `docs/RELEASING.md`.

## Names

SwarfGRBL is part of the **Swarf Suite** (GitHub org `Swarf-Suite`): **SwarfPath** (3D CAM, was Swarf, at
`~/src/SwarfPath`) and **SwarfEngrave** (planned, V-carve) make G-code; SwarfGRBL sends it. SwarfGRBL was KerfLine
(v2.1–v2.3) and, before that, GCode Controller 2.0. Everything now uses the new names: bundle id
`io.github.swarf-suite.swarfgrbl` (releases and builds from git alike), `SG*` modules, `swarfgrbl.*` defaults keys,
`_swarfgrbl._tcp` Bonjour, `~/Documents/SwarfGRBL`. On first launch `AppSetup.migrateDefaults` copies the old
`gcc.*` keys (from the KerfLine or GCode Controller 2.0 domain used last) and `AppSetup.migrateFolders` moves the
old library, inbox and data folders (`Setup.swift`). 1.0's data and its import paths keep the old names. The
Sparkle signing key's keychain account is still `kerfline`.

## Docs

`README.md` is user-facing and documents behaviour in detail (start-up `$$` checks, travel limits, resume, probing,
surfacing); keep it in sync when behaviour changes. `ROADMAP.md` tracks phases and pending machine bring-up checks.
`docs/SETUP.md` is the two-Mac walkthrough. Version 1.0 (Node.js + browser UI) lives only at tag `v1.0`.
