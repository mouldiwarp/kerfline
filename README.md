# SwarfGRBL

**A GRBL sender for the Mac, built for the FoxAlien XE-Ultra 8080 and other GRBL 1.1 machines.** Design on one
Mac, run the machine from another, and watch the same job live on both. It talks the standard GRBL serial protocol
over USB, so grblHAL and FluidNC machines should work too (untested).

SwarfGRBL is an independent open source project. It isn't affiliated with or endorsed by FoxAlien.

> [!WARNING]
> **This is experimental software that moves a machine with a spinning cutter. You use it at your
> own risk.** Keep a hardware emergency stop within reach. Air-cut new jobs with Z zeroed above the
> stock, and never leave a running machine unattended. Provided under the MIT License **without
> warranty of any kind**.

## How it fits together

One native Mac app, **SwarfGRBL**, runs on both Macs. On first launch you choose what each Mac does:

```
 SwarfPath / Fretboard ──HTTP POST──▶ ┌──────────── SwarfGRBL (Hub, design Mac :8080) ────────────┐
 ~/SwarfGRBL Inbox ──────────────────▶│ library · HTTP API · Bonjour _swarfgrbl · the app window   │
                                  └───────────────▲───────────────────────────────────────────┘
                                                  │ link (WebSocket; the agent finds the hub with Bonjour and reconnects)
                                  ┌───────────────┴──────────────── SwarfGRBL (Agent, garage Mac) ┐
                                  │ full copy of the library · GRBL streamer · the app window     │
                                  └───────────────┬───────────────────────────────────────────────┘
                                                  │ USB 115200 baud
                                              CNC machine (GRBL 1.1)
```

- **Hub** (design Mac): receives files from SwarfPath, Fretboard, the inbox folder and drag and drop, and keeps the
  library in `~/Documents/SwarfGRBL`.
- **Agent** (Mac next to the machine): drives the machine over USB. **It streams each job from its own copy of the
  file**, so a Wi-Fi dropout can't starve the machine mid-cut, and it keeps working if the hub Mac is asleep or off.
- **Either Mac can own the machine**: whichever has it plugged in over USB drives it. The other Mac shows the same
  live position, progress and console, and can start, pause, stop, jog and zero it remotely.
- **The library is fully synced.** Both Macs keep a complete copy, in an ordinary Finder folder. Changes on either
  Mac, in the app or in Finder, reach the other one whenever they're connected. If the same file was changed on both
  while they were apart, the app asks which to keep (or keeps both).

1.0 (tag `v1.0`) was a Node.js hub and agent with a browser UI. 2.0 replaced it with this app and kept all its features;
1.0's code is still in the repository at that tag.

## Installing

SwarfGRBL needs **macOS 26** on an Apple-silicon or Intel Mac.

### Download

Get **[SwarfGRBL.dmg](https://github.com/Swarf-Suite/SwarfGRBL/releases/latest/download/SwarfGRBL.dmg)** from the
[latest release](https://github.com/Swarf-Suite/SwarfGRBL/releases/latest), open it, and drag SwarfGRBL to Applications.
Releases are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning. (The first
signed release is waiting on the Apple Developer membership; until it's out, build from source.)

### From source

This needs **Xcode 26** (or its Command Line Tools, for Swift 6.2):

```sh
git clone https://github.com/Swarf-Suite/SwarfGRBL.git
cd SwarfGRBL
scripts/build-app.sh
```

That compiles the app for that Mac (about a minute; a few on an older Mac) and installs it in `~/Applications`. It
is **SwarfGRBL.app**; open it from Spotlight: ⌘Space, then type "SwarfGRBL". Nothing starts at login. A build from source
and the download are the same app to macOS (same bundle id and settings); only how it updates differs.

**Coming from KerfLine or GCode Controller 2.0?** SwarfGRBL is the same app, renamed. Its first launch brings over the
old app's settings (role, names, machine, jog step), and moves the library to `~/Documents/SwarfGRBL`, the inbox to
`~/SwarfGRBL Inbox` and the data to `~/Library/Application Support/SwarfGRBL` (1.0's own data stays where it was).
macOS asks once more for Documents, Local Network and USB access. Update both Macs together: the link between them
uses a new Bonjour name, so an old and a new app won't find each other.

### Either way

- **First launch** asks whether this Mac is the **Hub** or an **Agent**, its name, and whether the machine is on
  USB here, simulated, or not on this Mac. Change it later in **Settings** (⌘,).
- **No machine?** If none is found on USB (or, on the design Mac, the garage Mac isn't connected), a banner offers
  **Use the simulator**: the built-in GRBL simulator runs in its place, marked **SIM**, until **Back to the
  machine** or the next launch. It never moves the real machine, and the saved setup isn't changed.
- **macOS asks** to let it find devices on the local network (click **Allow**, or the Macs can't link) and to
  access the Documents folder (click **Allow**, or the library can't open). Plugging the machine into an
  Apple-silicon laptop also asks once whether to allow the accessory.
- **No USB driver is needed**: macOS includes one for the CH340 chip in the FoxAlien's controller, which shows up as
  `/dev/cu.usbserial-*`. Skip the CH341 driver on FoxAlien's USB stick, which is for Windows.
- **While a Mac has the machine** it's kept from idle sleep (closing the lid still sleeps it).
- **Keep the screen on during jobs** (Settings, under This Mac; off until you turn it on, and set on each Mac): while
  the machine is connected and busy (a job running, paused or waiting for a bit change, or jogging, homing or
  probing), that Mac's screen doesn't dim, sleep or start the screen saver, and the Mac doesn't sleep. It works on
  either Mac, whichever has the machine, and lets go once the job ends. Like `caffeinate -d`, it changes no system setting.
- **Quitting** warns first if a job is running on this Mac's machine.

See **[docs/SETUP.md](docs/SETUP.md)** for the two-Mac walkthrough, including testing with the simulator.

## Updating

The app checks for updates every few hours (or **SwarfGRBL ▸ Check for Updates…**) and shows a banner when there's
one. **Update now** downloads it, installs it and restarts. If one Mac runs an older version than the other, both
show the banner, and either can tell the other to update. A Mac never updates while a job is running on it: an
update that's ready waits for the job to finish.

- **Downloaded app**: updates come from GitHub Releases, through [Sparkle](https://sparkle-project.org). Each update
  is checked against the release's signature before it's installed.
- **Built from source**: **Update now** pulls the new code into the checkout it was built from, rebuilds, and
  restarts. If you've changed files in the checkout, the update is refused rather than touching them. The other Mac
  can only update to code that's on GitHub: if this Mac runs commits that aren't pushed yet, the banner says so and
  offers **Check again** (for after you push) instead of an update, and an update that finds nothing new on GitHub
  doesn't rebuild or restart. By hand:
  `git pull && scripts/build-app.sh`, then quit and reopen the app. Until it's signed with a Developer ID, each
  rebuild is a new app to macOS's privacy settings, so after an update it may ask again for Documents and local
  network access. The start screen says so if it's waiting.

## The library

Your G-code lives in ordinary folders under **`~/Documents/SwarfGRBL`** on both Macs, one folder per
project. SwarfPath groups (one file per tool, side A / side B) arrive in a folder named after the group; single files land
at the top level. Re-sending a file with the same name replaces it, and the old version is kept in its history.

- **Library panel**: a folder tree beside the job controls. Drop files on a folder to add them there.
- **Manage** opens the library manager: make, rename and delete folders, rename and move files, restore an
  earlier version of a file (the last 5, for 30 days), and the Trash (deleted files are kept for 30 days).
- **Finder** works too: add, move, rename, edit or delete files and folders there, on either Mac, and the
  library follows within a few seconds. Moved files keep their history.
- **Conflicts**: if the same file was changed on both Macs while they weren't connected, the file shows a badge
  and **Resolve…** lets you keep either version, or both. Nothing is lost: the other version stays in the history.

## Sending G-code

- **Drag and drop** files onto the Library panel (or onto a folder in it), or click **Add…**.
- **Drop files in `~/SwarfGRBL Inbox`** on the design Mac. The hub imports them and moves them into `~/SwarfGRBL Inbox/imported`.
- **From an app or script**, POST the file to the hub:

  ```sh
  curl -X POST --data-binary @part.nc \
       -H 'X-Filename: part.nc' -H 'X-Source: SwarfPath' \
       http://design-mac.local:8080/api/jobs
  ```

  Optional headers: `X-Group` (a name that groups related files, such as side A and side B) and `X-Group-Index`
  (their order). The hub advertises itself over Bonjour as `_swarfgrbl._tcp`.
- **Scripts on the hub Mac** can also send any command to the app (connect, start, hold, resume, stop…) with
  `POST http://localhost:8080/api/command` and a JSON body. Requests from other computers are refused.

## The UI

| Area | What's there |
|---|---|
| Top bar | Hub, agent and machine status, who sent the last command, Home, Unlock, and big Hold / Stop buttons. Banners below it for alarms, settings checks, updates and conflicts |
| Left | Position readout (work and machine), zero, go to zero and home per axis, zero XY / Z, an amber **Go to XY0** and a red **Go to XYZ0** (which asks first, saying where the file expects Z zero), the big green **Probe Z** button for the touch plate, jog pad with step and feed presets (arrow keys and Page Up / Down also jog) |
| Centre | 3D toolpath: remaining cuts in steel, finished cuts in gold, live tool position, work zero and machine envelope. Progress bar with %, line count, elapsed time and time left |
| Right | Job controls (including running a file group in order, with a bit-change stop between files) and feed / spindle / rapid overrides, the file library, console with manual G-code entry, and macros |

**Home** on an axis row homes just that axis. On a GRBL built with single-axis homing (`H` in `$I`'s `[OPT:]`)
it sends `$HZ`, `$HX` or `$HY`, and for X and Y it homes Z first so the bit goes up clear of the work. Work zero is
kept. Stock GRBL 1.1 can't home one axis (and `$HX` there can leave it stuck in Home), so then SwarfGRBL never sends
it: once the machine has been homed, **Home** moves that axis back to where the full home left it, Z first.

## Probing Z and running file groups

**Probe Z** (under the position readout) sets work Z with a touch plate, as WorkBee Control did:

1. Measure the plate with calipers and enter its thickness in **Settings ▸ Touch plate**. Probing is
   refused until you do.
2. Jog the bit within 25 mm of the plate (the search distance can be changed in Settings), put the plate on the stock
   under it and clip the lead to the bit. The dialog shows the probe input live, so you can test the circuit first.
3. Press **Probe**. The bit touches down fast, lifts 2 mm and touches again slowly. Z0 is then set to the stock surface
   and the bit lifts clear. If nothing is touched, GRBL stops with ALARM 5 and nothing is changed.

**Where Z zero goes.** A file made to be zeroed on the spoilboard cuts a stock thickness too deep if you zero on the
material, and one made for the material top cuts in the air if you zero on the spoilboard. SwarfGRBL reads the
file's header and shows a badge under its name in the job panel and the 3D view: **Z zero: TOP of the material**
(gold) or **Z zero: SPOILBOARD** (orange). The start dialog repeats it in its checklist, and the bit-change step says
which surface to re-probe on. Fretboard Modeller and SwarfPath write it in words (`Z0 = TOP of stock`,
`Z0 = SPOILBOARD surface …`), and older Swarf files are read from their stock-space work zero. Other files can say it
the same way in a comment near the top; one that doesn't shows **Z zero: not stated**, so check where it was made.

**File groups.** SwarfPath sends one file per tool (and side A / side B) as a group. When you start a grouped file, the
start dialog offers to run the rest of the group in order. After each file the spindle is turned off and the job
waits in **Bit change**: fit the next bit, re-probe Z, then press **Start next** (or **End group** to stop there). All
the files are copied to the machine Mac before the first one starts, so a Wi-Fi dropout can't strand the group.

## How a job starts

Before the first line of a file, the app lifts the cutter straight up to the top of Z travel (if the machine isn't
homed, to the program's own highest Z), then moves X, then Y, over the program's first point. Only then does the
program run: it starts the spindle and lowers Z itself, directly over where it cuts, so nothing is crossed low. A
program that never says where X and Y start runs as it is.

## Start-up checks

Each time the controller connects, the app reads its settings and compares them with the values the FoxAlien was set up with:

| Setting | Value | Meaning |
|---|---|---|
| `$20` | 1 | Soft limits on |
| `$21` | 1 | Hard limits on |
| `$22` | 1 | Homing on |
| `$23` | 3 | Homes front-left |
| `$27` | 3 | Backs 3 mm off the switches |
| `$30` | 24000 | Spindle top speed |
| `$32` | 0 | Laser mode off |
| `$130`–`$132` | 800, 800, 100 | Travel |

Anything different is listed at the top of the window with a button to set it back. The banner also flags the app's travel if it doesn't match the controller's. When everything matches it says so and can be dismissed. The list lives in `swift/Sources/SGCore/MachineCheck.swift`.

Some things the controller can't report. The banner and the Start dialog remind you to check them by hand. In particular, **the controller's Laser/Spindle switch must be on LASER**: the 1.5 kW spindle takes its PWM from the laser port.

## Staying within the machine's travel

If soft limits are off (`$20=0`), GRBL will drive into a limit switch if asked. Hitting one stops the machine dead in ALARM, often reported as ALARM 3, and the position is then lost. Once the machine is homed, the app checks every move against the travel set in Settings:

- **Jogs** stop at the end of travel. A notification says when one was shortened, and a jog that can't move is refused.
- **Typed commands and macros** are refused, with a notification, if any line would go past the travel. This covers absolute, relative, inch and `G53` moves. The whole batch is checked before any of it is sent.
- **Jobs** are refused at Start if, from the current work zero, the program would go outside the travel. The usual cause is a Z zero set high enough that the program's safe-Z moves would hit the top switch.

Until the machine is homed, its position isn't known, so none of this applies. The Jog panel says so.

## Cutting with the spindle off

GRBL will happily run a cutting move (`G1`, `G2`, `G3`) with the spindle stopped, which drives a still cutter into the
work. So the app checks each file for a feed move made before the program has started the spindle with `M3`/`M4` and an
`S` speed (or after `M5`, `S0` or a program end). Probing moves (`G38.x`) don't count, and an `M3` on the same line as
the cut does, because GRBL starts the spindle before the move.

A file like that, such as Fretboard Modeller's output when its max spindle is set to manual, gets a warning in the
Start and Resume dialogs naming the first such line. Start stays disabled until you tick **The spindle is started by hand
for this job**. The Mac that owns the machine also refuses the job without that confirmation, so a script or the other
Mac can't skip it. When resuming, only cuts from the resume line on count. A file group is checked in full at Start, and
the files after the first then run without asking again.

## Dealing with a problem mid-cut

- **Pause** (in the Job panel) gets the cutter out of the way: it stops at the line the cutter is on, turns the spindle
  off and raises Z to 1 mm under the top of travel (only to safe Z above work zero if the machine isn't homed). GRBL
  can't move at all during a plain feed hold, and the FoxAlien's firmware (`[OPT:VZ,…]`) has no parking, so Pause stops
  rather than holds. **Resume…** then opens the resume dialog at that line (below); **Stop** ends the job there.
- **Hold** in the top bar is GRBL's plain feed hold: the motion stops with the spindle still running and Z where it is.
  The Job panel then offers **Stop spindle**, and **Resume** spins it back up, waits for it, and carries on.
- To move the cutter away after a Hold (clear chips, free a part, change a broken bit), press **Stop**. The job remembers the line the cutter was on, which is earlier than the line count because GRBL queues moves ahead.
- When you are ready, use **Resume from line…** in the Job panel. It shows the program around that line, and you can go back a line or two if unsure. It then:
  1. restores the program's modes (units, distance mode, plane, work offset);
  2. lifts straight up to the top of Z travel (if the machine isn't homed, to the program's own highest Z; it never
     moves down here);
  3. starts the spindle and waits 4 s, before moving anywhere;
  4. moves X, then Y, over the start of that line;
  5. drops quickly to just above the cut (the program's travel height, at most 5 mm above it), then lowers onto the
     cut at 300 mm/min (or the Z jog speed, if lower);
  6. continues streaming.
- If the machine alarmed or was switched off, home it first. Work zero is kept. Don't re-probe Z unless the bit changed.

## Surfacing the spoilboard

**Library ▸ Surfacing…** (or **Machine ▸ Surfacing…**) makes a program to flatten the spoilboard:

1. Fit the surfacing cutter.
2. Jog the bit's centre to the **left edge** of the board, on its **centre line** front to back, and press
   **Zero XY here**.
3. Set Z zero on the surface (**Zero Z here** with the bit touching it, or **Probe Z…**).
4. Enter the length (X, to the right of zero) and width (Y, centred on zero) to flatten, and the depth to remove
   (0.5 mm by default).

It cuts in a zigzag along X, 50% stepover. The cutter never plunges: each pass ramps in at 2° along the first line,
then goes back over the ramp at full depth. It runs at least r × (1 − 1/√2) past each edge so the round cutter
reaches the corners: 4 mm by default for a 24 mm cutter. **Add to library** puts it in the library and the 3D view,
and you start it from the Job panel as usual, with the out-of-travel check. The settings are remembered.

## Development

The code is a Swift package in `swift/`:

| Module | What |
|---|---|
| `SGCore` | G-code and GRBL parsing, machine and job state, resume, progress, travel checks, surfacing, settings check |
| `SGMachine` | Serial port, GRBL simulator, the streaming session |
| `SGLibrary` | The library on disk: content store, SQLite, the Finder folder, history, Trash, sync changes |
| `SGNet` | The hub's HTTP API, Bonjour, the link between the Macs, sync, the inbox |
| `SGUI` | The SwiftUI app and its Metal 3D view |
| `swarfgrbl-cli` | Command-line tool |

```sh
scripts/ci.sh                         # the tests, in a clean checkout (as GitHub CI runs them)
cd swift
swift test
swift run SwarfGRBL             # run the app without installing it
swift run swarfgrbl-cli ports                   # serial ports (* = looks like GRBL)
swift run swarfgrbl-cli stream --simulate ../samples/test-square.nc
```

Releases are built by GitHub Actions when a `vX.Y` tag is pushed: see [docs/RELEASING.md](docs/RELEASING.md).
See [ROADMAP.md](ROADMAP.md) for what's planned.

## License

MIT
