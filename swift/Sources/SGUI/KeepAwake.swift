// While this Mac owns the machine, stop it going to sleep when it's left idle: asleep, it drops
// off the network (the other Mac loses the machine) and a running job's USB stream would stall.
// Like `caffeinate -i`, ported from 1.0's launcher: it changes no system setting and ends when the
// machine disconnects or the app quits. Closing the lid still sleeps the Mac.
//
// "Keep the screen on during jobs" (per Mac, in Settings) adds `caffeinate -d` while the machine is busy:
// the display doesn't dim, sleep or start the screen saver, and macOS doesn't App Nap the app.

import Foundation
import IOKit.pwr_mgt

@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private var screenActivity: NSObjectProtocol?

    var isOn: Bool { assertion != 0 }
    var screenOn: Bool { screenActivity != nil }

    /// Keep the display on (which also keeps the Mac awake and the app out of App Nap). Returns true if this
    /// changed anything.
    @discardableResult
    func setScreen(_ on: Bool) -> Bool {
        if on, screenActivity == nil {
            screenActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "SwarfGRBL is running the CNC machine")
            return true
        }
        if !on, let a = screenActivity {
            ProcessInfo.processInfo.endActivity(a)
            screenActivity = nil
            return true
        }
        return false
    }

    /// Returns true if this changed anything.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on, assertion == 0 {
            var id: IOPMAssertionID = 0
            let reason = "SwarfGRBL is connected to the CNC machine" as CFString
            guard IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess
            else { return false }
            assertion = id
            return true
        }
        if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            return true
        }
        return false
    }
}
