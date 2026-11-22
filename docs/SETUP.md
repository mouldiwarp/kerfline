# Setting up two Macs

This walks through the setup this project was built for: a **design Mac** indoors as the hub, and a
**machine Mac** in the garage plugged into the CNC over USB. With the simulator you can test the whole
loop between the two Macs before connecting the machine.

Both Macs must be on the same Wi-Fi or LAN, with macOS 26 and Xcode 26 (or its Command Line Tools).

## 1. Both Macs: build and install the app

```sh
git clone https://github.com/mouldiwarp/kerfline.git
cd kerfline
scripts/build-app.sh
```

This installs KerfLine in `~/Applications` as the file `GCode Controller 2.0.app`; the menu bar, Dock and Finder show it as KerfLine. Open it from Spotlight (⌘Space, "KerfLine").
Keep the checkout: the app updates itself from it.

## 2. Design Mac: the hub

On first launch choose **Hub**, give the Mac a name (it appears beside every command and on the other Mac),
and choose where the machine is: **Not on this Mac**, unless it's plugged in here.

Click **Allow** when macOS asks:
- to find devices on the local network, or the garage Mac can't link;
- to access the Documents folder, where the library lives.

Swarf and Fretboard send to `http://<design-mac>.local:8080/api/jobs`, and files dropped into `~/GCode Inbox` are added
to the library.

## 3. Garage Mac: the agent

On first launch choose **Agent**, and for the machine:
- **Simulator** to test without the machine;
- **USB** when it's plugged in.

Leave the hub address empty: the agent finds the hub with Bonjour. If it doesn't (some routers block multicast),
enter the hub Mac's name, such as `design-mac.local`, in Settings (⌘,).

Click **Allow** for local network and Documents access, as on the hub. With the machine, an Apple-silicon Mac also asks
once whether to allow the USB accessory.

The FoxAlien's controller uses a **CH340** USB-serial chip, which macOS supports without a driver. It appears as
`/dev/cu.usbserial-…` (or `/dev/cu.wchusbserial…` if WCH's driver is installed); the app finds either. To see the
ports, run `swift run gcc ports` in the `swift` folder. The likely GRBL port is marked with `*`.

## 4. Test the sync

1. On the design Mac, drag `samples/demo-body.nc` onto the Library panel. It appears on the garage Mac within a
   few seconds, and in its `~/Documents/GCode Controller` folder.
2. On the garage Mac, click **Unlock** (the simulator starts locked, like GRBL with homing on), jog to the middle
   of the bed, and click **Zero all**.
3. Start the job from either Mac. Both show the same progress in 3D and the same %.
4. Pause from one Mac (Z rises to the top) and resume from the other (**Resume…**, then **Resume from line**).
5. Quit the app on the design Mac while the job runs. The garage keeps cutting and shows "Hub offline". Open it
   again and the design Mac catches up.

## Troubleshooting

| Problem | Fix |
|---|---|
| Garage says "Hub offline" | Check the app is running on the design Mac. Enter its address in Settings. Check Local Network is allowed for GCode Controller in System Settings ▸ Privacy & Security ▸ Local Network, on both Macs. |
| Stuck on "Starting…" | macOS is waiting for you to allow access to the Documents folder. The question may be behind other windows. |
| "No USB GRBL controller found" | Run `swift run gcc ports`. Check the cable (some are charge-only) and that the machine's controller is powered. |
| Machine shows **ALARM** at start | Normal for GRBL with homing on. Click **Home** (or **Unlock** if you know the position is safe). |
| Toolpath drawn outside the envelope | Set the machine travel in Machine Settings, or use the controller's travel from the settings-check banner. |
