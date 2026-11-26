// Updating a build from git, as 1.0 did: fetch to see whether there's newer code, then pull,
// rebuild and reinstall with scripts/build-app.sh, and relaunch the new copy. The build script
// stamps the commit it built into Info.plist, so the app knows which code it runs even after the
// checkout is pulled. Release builds (from GitHub Releases) update with Sparkle instead: see
// ReleaseUpdater.

import AppKit
import Foundation
import SGCore

/// The code this copy of the app was built from.
public struct BuildInfo: Sendable, Equatable {
    public var code: CodeVersion
    /// The git checkout it was built from (nil: not known, so it can't update itself).
    public var repo: URL?
    /// The app bundle, when running from one (not `swift run`).
    public var bundle: URL?
    /// A release build's appcast (Sparkle's SUFeedURL): it updates from GitHub Releases, not git.
    public var feed: URL?

    public init(code: CodeVersion, repo: URL?, bundle: URL?, feed: URL? = nil) {
        self.code = code
        self.repo = repo
        self.bundle = bundle
        self.feed = feed
    }

    /// Read from Info.plist (stamped by build-app.sh); a dev run finds the checkout above the executable.
    public static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "2.0.0"
        let commit = info["SGCommit"] as? String
        let time = (info["SGCommitTime"] as? String).flatMap(Double.init).map { $0 * 1000 }
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:))
        var repo = (info["SGRepoPath"] as? String).map { URL(fileURLWithPath: $0) }
        if repo == nil, feed == nil, let exe = Bundle.main.executableURL { repo = findRepo(above: exe) }
        if let r = repo, !FileManager.default.fileExists(atPath: r.appending(path: ".git").path) { repo = nil }
        return BuildInfo(code: CodeVersion(version: version, commit: commit, time: time), repo: repo, bundle: bundle, feed: feed)
    }()

    static func findRepo(above url: URL) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: ".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A release build, updated from GitHub Releases.
    public var isRelease: Bool { feed != nil && bundle != nil }

    /// A build from git rebuilds and relaunches the app bundle, so it needs both; a release
    /// build downloads the next release.
    public var canUpdate: Bool { isRelease || (repo != nil && bundle != nil) }
}

/// What a check found.
public struct UpdateCheck: Sendable, Equatable {
    /// Commits on the branch's upstream that this build doesn't have.
    public var behind: Int
    /// The newest of them.
    public var latest: CodeVersion?
    /// The first line of each new commit's message, newest first.
    public var changes: [String]
    /// A release build: the version on offer.
    public var version: String? = nil
}

public struct UpdateError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs git and the build script in the checkout.
public struct Updater: Sendable {
    public var repo: URL
    /// The commit this build came from (nil: compare with the checkout's HEAD).
    public var built: String?
    /// The rebuild step (default: scripts/build-app.sh, installing over `installDir`).
    public var build: [String]

    public init(repo: URL, built: String?, installDir: URL?) {
        self.repo = repo
        self.built = built
        var b = [repo.appending(path: "scripts/build-app.sh").path]
        if let installDir { b.append(installDir.path) }
        build = b
    }

    public init(repo: URL, built: String?, build: [String]) {
        self.repo = repo
        self.built = built
        self.build = build
    }

    /// Fetch, then count the upstream's commits this build doesn't have (a pull without a rebuild counts).
    public func check() async throws -> UpdateCheck {
        _ = try await git(["fetch", "--quiet"], hint: "Couldn't reach GitHub")
        let base = try await baseCommit()
        let count = Int(try await git(["rev-list", "--count", "\(base)..@{u}"]).trimmed) ?? 0
        guard count > 0 else { return UpdateCheck(behind: 0, latest: nil, changes: []) }
        let log = try await git(["log", "--format=%H %ct %s", "-n", "20", "\(base)..@{u}"])
        var latest: CodeVersion?
        var changes: [String] = []
        for line in log.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { continue }
            if latest == nil { latest = CodeVersion(version: "", commit: parts[0], time: Double(parts[1]).map { $0 * 1000 }) }
            if parts.count == 3 { changes.append(parts[2]) }
        }
        return UpdateCheck(behind: count, latest: latest, changes: changes)
    }

    /// The commit to compare with: this build's, if the checkout has it.
    private func baseCommit() async throws -> String {
        if let built, (try? await git(["cat-file", "-e", "\(built)^{commit}"])) != nil { return built }
        return try await git(["rev-parse", "HEAD"]).trimmed
    }

    /// Pull and rebuild; `step` reports progress. Nothing is installed unless the build succeeds.
    /// Returns false, without building, when the pull brings nothing this build doesn't already have (the other Mac
    /// may run code that isn't on GitHub yet): rebuilding and restarting then would only start the same code again.
    @discardableResult
    public func update(step: @Sendable (String) async -> Void) async throws -> Bool {
        await step("Downloading the latest code")
        _ = try await git(
            ["pull", "--ff-only", "--quiet"],
            hint: "If files in \(repo.path) were changed by hand, commit or stash them first. Nothing was changed")
        if let built, try await git(["rev-parse", "HEAD"]).trimmed == built { return false }
        await step("Building the app (a few minutes)")
        guard let exe = build.first else { return true }
        _ = try await run(exe, Array(build.dropFirst()), hint: "The build failed, so this version stays installed")
        return true
    }

    /// Whether `commit` is on the branch's upstream (GitHub), as of the last fetch. The other Mac can only update to
    /// code it can pull. False for a commit that's only in this checkout, or not in it at all.
    public func isPublished(_ commit: String) async -> Bool {
        (try? await git(["merge-base", "--is-ancestor", commit, "@{u}"])) != nil
    }

    func git(_ args: [String], hint: String? = nil) async throws -> String {
        try await run("/usr/bin/git", ["-C", repo.path] + args, hint: hint)
    }

    /// Run a program to completion, off the main thread. Throws with the end of its output.
    func run(_ exe: String, _ args: [String], hint: String? = nil) async throws -> String {
        let repo = repo
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = repo
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            // A Finder-launched app has a minimal PATH; the build needs swift, codesign and git.
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                let tail = text.split(separator: "\n").suffix(6).joined(separator: "\n")
                throw UpdateError([hint, tail.isEmpty ? "exit \(p.terminationStatus)" : tail].compactMap { $0 }.joined(separator: ": "))
            }
            return text
        }.value
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Quit, and open `app` again once this process has gone (open would just reactivate it while
/// it's running). As 1.0's launcher did after an update.
@MainActor
public func relaunch(_ app: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [
        "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path, String(getpid()),
    ]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    // Not straight from here: this is called from a main-actor task, and terminate's wait for
    // applicationShouldTerminate's tidy shutdown would block the main actor that shutdown needs.
    // From the run loop instead, the main actor stays free while it waits.
    RunLoop.main.perform(inModes: [.default]) { NSApp.terminate(nil) }
}
