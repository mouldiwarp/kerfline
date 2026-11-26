// Updating a release build (one downloaded from GitHub Releases) with Sparkle. Sparkle checks the
// appcast published with each release, checks the update's EdDSA signature, and swaps the app in
// place. Its windows are replaced by this user driver, which feeds the app's own update banner, so
// a release build updates the same way a build from git does: Update now on either Mac, the other
// Mac can ask it to update, and it never installs while a job runs here.

import AppKit
import Foundation
import SGCore
import SGMachine
import os
@preconcurrency import Sparkle

private let log = Logger(subsystem: "io.github.mouldiwarp.kerfline", category: "update")

@MainActor
final class ReleaseUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    /// The banner's state.
    var onStatus: (UpdateStatus) -> Void = { _ in }
    /// A step worth telling the other Mac about.
    var onStep: (String) -> Void = { _ in }
    var onToast: (Toast.Level, String) -> Void = { _, _ in }
    /// Whether a job is running on this Mac's machine (installing would stop it).
    var jobRunning: () -> Bool = { false }

    private var updater: SPUUpdater!
    /// Sparkle is waiting for an answer to "an update was found".
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    /// Sparkle is waiting for an answer to "ready to install and relaunch".
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    /// Install as soon as an update is found (Update now, or asked by the other Mac).
    private var installWhenFound = false
    private var manualCheck = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var lastPercent = -1
    private var status: UpdateStatus = .idle {
        didSet { onStatus(status) }
    }

    init(bundle: Bundle = .main) {
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
    }

    func start() throws {
        try updater.start()
    }

    /// A manual check reports "up to date"; a background one stays quiet unless it finds something.
    func check(manual: Bool) {
        guard updater.canCheckForUpdates else { return }
        manualCheck = manual
        if manual { updater.checkForUpdates() } else { updater.checkForUpdatesInBackground() }
    }

    /// Download and install the update (checking for it first if none is waiting).
    func install() {
        if let reply = foundReply {
            foundReply = nil
            reply(.install)
        } else if let reply = readyReply {
            readyReply = nil
            reply(.install)
        } else {
            installWhenFound = true
            status = .running("Checking for the update")
            if updater.canCheckForUpdates { updater.checkForUpdates() }
        }
    }

    /// Restart into an update that's been downloaded and is waiting (held while a job ran).
    func installReady() -> Bool {
        guard let reply = readyReply else { return false }
        readyReply = nil
        reply(.install)
        return true
    }

    /// Later: remind again at the next scheduled check.
    func dismiss() {
        foundReply?(.dismiss)
        foundReply = nil
        installWhenFound = false
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !installWhenFound { status = .checking }
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if item.isInformationOnlyUpdate {
            reply(.dismiss)
            return
        }
        if installWhenFound {
            installWhenFound = false
            reply(.install)
            return
        }
        foundReply = reply
        let version = item.displayVersionString
        status = .available(UpdateCheck(
            behind: 1, latest: CodeVersion(version: version), changes: item.title.map { [$0] } ?? [], version: version))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if installWhenFound {
            onToast(.info, "There's no newer release to install")
        } else if manualCheck {
            onToast(.info, "SwarfGRBL \(BuildInfo.current.code.version) is the latest release")
        }
        installWhenFound = false
        manualCheck = false
        status = .idle
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        log.error("update failed: \(error.localizedDescription, privacy: .public) \(String(describing: error), privacy: .public)")
        let message = error.localizedDescription
        // A background check that couldn't reach GitHub isn't worth a banner.
        if manualCheck || installWhenFound || isUnderWay {
            status = .failed(message)
        } else {
            status = .idle
        }
        installWhenFound = false
        manualCheck = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        lastPercent = -1
        step("Downloading the update")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        let percent = Int(Double(received) / Double(expected) * 100)
        // The banner follows the download; the other Mac only hears about each step.
        if percent / 5 != lastPercent / 5 {
            lastPercent = percent
            status = .running("Downloading the update (\(min(percent, 100))%)")
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        step("Checking and unpacking the update")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if jobRunning() {
            readyReply = reply
            status = .ready
            onStep("Updated. Restart it when the job has finished")
        } else {
            step("Installing and restarting")
            reply(.install)
            // Without a relaunch Sparkle installs when the app quits, so quit (see below).
            if AppSetup.devHome != nil {
                RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
            }
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        status = .running("Installing")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        NSApp.activate()
    }

    func dismissUpdateInstallation() {
        foundReply = nil
        readyReply = nil
        installWhenFound = false
        manualCheck = false
        switch status {
        case .failed: break
        default: status = .idle
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Sparkle relaunches the app without its environment, so a dev run (SG_HOME) would come back
    /// as the real app, on the real library: it just quits, and is installed as it quits.
    nonisolated func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        AppSetup.devHome == nil
    }

    // MARK: Helpers

    private var isUnderWay: Bool {
        if case .running = status { true } else { false }
    }

    private func step(_ text: String) {
        status = .running(text)
        onStep(text)
    }
}
