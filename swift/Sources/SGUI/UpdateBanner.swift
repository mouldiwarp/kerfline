// The update banner, as 1.0's UpdateBanner.tsx: newer code on GitHub, an update under way or
// finished, or the other Mac running older code (which it can be asked to update).

import SGCore
import SGNet
import SwiftUI

struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    let s: AppState

    var body: some View {
        switch model.update {
        case .running(let step):
            Banner(kind: .info, text: "Updating this Mac: \(step)…") { ProgressView().controlSize(.small) }
        case .ready:
            Banner(kind: .info, text: model.jobRunningHere ? "Updated. Restart when the job has finished to run the new version." : "Updated. Restart to run the new version.") {
                Button("Restart") { model.restartNow() }.gccButton(.primary, .small).disabled(model.jobRunningHere)
            }
        case .failed(let message):
            Banner(kind: .danger, text: "Update failed: \(message)") {
                Button("Try again") { tryUpdate() }.gccButton(.normal, .small).disabled(model.jobRunningHere)
                Button("Dismiss") { model.dismissUpdate() }.gccButton(.ghost, .small)
            }
        case .available(let c):
            Banner(kind: .info, text: availableText(c)) {
                if model.jobRunningHere { Text("Finish the job first").font(.system(size: 11.5)).foregroundStyle(Color.steel) }
                Button("Update now") { tryUpdate() }.gccButton(.primary, .small).disabled(model.jobRunningHere)
                    .help(model.build.isRelease ? "Download the new release, install it and restart" : "Download the latest code, rebuild the app and restart it")
                Button("Later") { model.dismissUpdate() }.gccButton(.ghost, .small)
            }
        case .idle, .checking:
            peerBanner
        }
    }

    @ViewBuilder private var peerBanner: some View {
        let other = s.link.via == .hub ? s.link.agentName : s.link.hubName
        if let other, let theirs = s.link.peerCode {
            switch model.peerCode {
            case .ahead where model.unpublishedCode != nil:
                // Updating would pull from GitHub, which doesn't have this Mac's code: it would rebuild the same version.
                Banner(kind: .info, text: "\(other) runs older code (\(describe(theirs))) than this Mac (\(describe(model.build.code))), but this Mac's code isn't on GitHub yet, so \(other) can't update to it. Push it, then check again.") {
                    Button("Check again") { Task { await model.checkForUpdates(manual: true) } }.gccButton(.normal, .small)
                        .help("Look on GitHub again for this Mac's code")
                }
            case .ahead:
                Banner(kind: .info, text: "\(other) runs older code (\(describe(theirs))) than this Mac (\(describe(model.build.code))).") {
                    if let role = model.peerRole {
                        Button("Update \(other)") { model.send(.update(target: role)) }.gccButton(.normal, .small)
                            .help("Ask \(other) to update itself and restart")
                    }
                }
            case .behind where model.build.canUpdate:
                Banner(kind: .info, text: "This Mac runs older code (\(describe(model.build.code))) than \(other) (\(describe(theirs))).") {
                    Button("Update now") { tryUpdate() }.gccButton(.normal, .small).disabled(model.jobRunningHere)
                }
            default:
                EmptyView()
            }
        }
    }

    private func tryUpdate() {
        do { try model.beginUpdate() } catch { model.toast(.error, error.localizedDescription) }
    }

    private func availableText(_ c: UpdateCheck) -> String {
        if let v = c.version { return "SwarfGRBL \(v) is available (this Mac has \(model.build.code.version))" }
        let what = c.behind == 1 ? "1 new change" : "\(c.behind) new changes"
        let latest = c.changes.first.map { ", latest: \($0)" } ?? ""
        return "An update is available: \(what)\(latest)"
    }
}

/// "2.1, abc1234, 18 Nov"
func describe(_ c: CodeVersion) -> String {
    var parts: [String] = []
    if !c.version.isEmpty { parts.append(c.version) }
    if c.commit != nil { parts.append(c.shortCommit) }
    if let t = c.time { parts.append(Date(timeIntervalSince1970: t / 1000).formatted(.dateTime.day().month(.abbreviated))) }
    return parts.isEmpty ? "unknown" : parts.joined(separator: ", ")
}
