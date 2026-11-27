import AppKit
import Common

/// Persistent notices for one bug: live windows that AeroSpork collects all at once, typically when
/// the display sleeps and the screen locks, and that it then never detects again. Workspace switches
/// keep working on the tree but move nothing on screen, because the windows are no longer in it.
///
/// Seen once, with nothing in the log to say why: at the second the display went to sleep, Claude's
/// and Orion's windows "died" together, and for the next two hours no refresh brought them back.
/// These records are what the next occurrence needs: which windows went, what each app listed in that
/// pass, which apps did not answer, and whether and when each window came back.
///
/// Cheap and rare, as `AppLog` requires. A single window closing logs nothing here. A mass loss is a
/// handful of records a day at most, and the rest is a set lookup per refresh that is empty unless
/// something was lost.
@MainActor
enum WindowLossDiagnostics {
    /// Windows collected in a mass loss and not seen since, with the bundle id and the time.
    private static var lost: [UInt32: (bundleId: String, at: Date)] = [:]

    static var lostWindowIdsForTests: Set<UInt32> { Set(lost.keys) }
    static func resetForTests() { lost = [:] }

    /// From `refresh()`, with every window it is about to collect in this pass.
    static func noteCollected(
        _ windows: [Window],
        listedByApp: [MacApp: [UInt32]],
        frontmostBundleId: String?,
    ) {
        guard windows.count >= 2 else { return } // one window closing is not the bug
        let collected = windows.map { "\($0.windowId) (\($0.app.bundleId ?? "?"))" }.joined(separator: ", ")
        // What each affected app said this pass. "listed 0" for a running app is the lock-screen symptom.
        let affectedBundleIds = Set(windows.map { $0.app.bundleId ?? "?" })
        let listed = listedByApp
            .filter { affectedBundleIds.contains($0.key.bundleId ?? "?") }
            .map { "\($0.key.bundleId ?? "?") listed \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        let timedOut = MacApp.timedOutThisPass
            .map { pid in MacApp.allAppsMap[pid]?.bundleId ?? "pid \(pid)" }
            .sorted()
            .joined(separator: ", ")
        AppLog.session.notice(
            "\(windows.count, privacy: .public) windows collected in one refresh: \(collected, privacy: .public). Apps: \(listed.isEmpty ? "none answered" : listed, privacy: .public). Timed out: \(timedOut.isEmpty ? "none" : timedOut, privacy: .public). Frontmost: \(frontmostBundleId ?? "none", privacy: .public)",
        )
        let now = Date.now
        for window in windows {
            lost[window.windowId] = (window.app.bundleId ?? "?", now)
        }
        // Bounded: an entry a day old is a window that really closed.
        lost = lost.filter { now.timeIntervalSince($0.value.at) < 24 * 60 * 60 }
    }

    /// From the end of `refresh()`. Free when nothing was lost.
    static func noteWindowsBack() {
        if lost.isEmpty { return }
        for (windowId, entry) in lost where MacWindow.allWindowsMap[windowId] != nil {
            lost.removeValue(forKey: windowId)
            AppLog.session.notice(
                "window \(windowId, privacy: .public) (\(entry.bundleId, privacy: .public)) is back after \(Int(Date.now.timeIntervalSince(entry.at)), privacy: .public)s",
            )
        }
    }

    /// One line after a wake or an unlock: whether refreshes ran, and what is still missing.
    static func summary(after reason: String) {
        let stillLost = lost.map { "\($0.key) (\($0.value.bundleId))" }.sorted().joined(separator: ", ")
        // A visible regular app with no managed window is what the user sees as "switching does nothing".
        let managedPids = Set(MacWindow.allWindows.map { $0.app.pid })
        let unmanaged = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
            .filter { !managedPids.contains($0.processIdentifier) }
            .compactMap(\.bundleIdentifier)
            .sorted()
            .joined(separator: ", ")
        AppLog.session.notice(
            "after \(reason, privacy: .public): managing \(MacWindow.allWindows.count, privacy: .public) windows. Lost and not back: \(stillLost.isEmpty ? "none" : stillLost, privacy: .public). Running apps with no managed window: \(unmanaged.isEmpty ? "none" : unmanaged, privacy: .public)",
        )
    }
}
