import AppKit
import Common

class GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        let nsApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if nsApp?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        Task { @MainActor in
            if let nsApp { MacApp.noteAppChanged(nsApp) }
            if !TrayMenuModel.shared.isEnabled { return }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                runRefreshSession(.globalObserver(notifName), screenIsDefinitelyUnlocked: false, optimisticallyPreLayoutWorkspaces: true)
            } else {
                runRefreshSession(.globalObserver(notifName), screenIsDefinitelyUnlocked: false)
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        runDetached("onHideApp") {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    @MainActor
    static func initObserver() {
        // Otherwise the first wake reads as a changed monitor set, and rebalances workspaces.
        lastMonitorSignature = monitorSetSignature()
        MacApp.startRegularAppSweep()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)

        // Monitor change detection
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                onMonitorConfigurationChanged()
            }
        }

        // Sleep and the lock screen. A wake used to be noticed only through the screen parameters
        // changing, and while the screen is locked the lock screen app answers for every window, so
        // the refresh that ran then could not see the user's windows. Ask again once the session is
        // back, and again a little later: apps can take seconds to answer Accessibility after a wake.
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWakeOrUnlock("didWake", screenIsDefinitelyUnlocked: false) }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWakeOrUnlock("screensDidWake", screenIsDefinitelyUnlocked: false) }
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWakeOrUnlock("sessionDidBecomeActive", screenIsDefinitelyUnlocked: false) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in onWakeOrUnlock("screenIsUnlocked", screenIsDefinitelyUnlocked: true) }
        }

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            runDetached("didActivateApp") {
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                resetClosedWindowsCache()
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch () {
                    // Detect clicks on desktop of different monitors
                    case _ where clickedMonitor.activeWorkspace != focus.workspace:
                        _ = try await runSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.activeWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        runRefreshSession(.globalObserverLeftMouseUp, screenIsDefinitelyUnlocked: true)
                }
            }
        }
    }

    @MainActor
    private static func onWakeOrUnlock(_ reason: String, screenIsDefinitelyUnlocked: Bool) {
        if !TrayMenuModel.shared.isEnabled { return }
        runRefreshSession(.globalObserver(reason), screenIsDefinitelyUnlocked: screenIsDefinitelyUnlocked)
        scheduleFollowUpRefresh(after: 2, "\(reason)FollowUp")
        scheduleFollowUpRefresh(after: 6, "\(reason)FollowUp")
        // After the last follow-up has had time to run: did the refreshes happen, and did they help.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            WindowLossDiagnostics.summary(after: reason)
        }
    }

    // DisplayLink docks fire didChangeScreenParametersNotification in bursts during a single
    // connect (multi-stage settle) and on flap. Coalesce bursts into one refresh+rebalance.
    @MainActor private static var pendingMonitorReconfigTask: Task<Void, Never>?
    // Set-based signal: rebalance when the monitor arrangement actually changes, not just the count.
    @MainActor private static var lastMonitorSignature: String?

    @MainActor
    private static func onMonitorConfigurationChanged() {
        pendingMonitorReconfigTask?.cancel()
        pendingMonitorReconfigTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            applyMonitorConfigurationChange()
        }
    }

    @MainActor
    private static func applyMonitorConfigurationChange() {
        guard let token: RunSessionGuard = .isServerEnabled else { return }

        let signature = monitorSetSignature()

        // Not left to `gcMonitors`, which only looks at the count: two panels trading places keep it.
        if signature != lastMonitorSignature { rearrangeWorkspacesOnMonitors() }

        // Run a refresh session to update monitor state
        runRefreshSession(.globalObserver("didChangeScreenParameters"), screenIsDefinitelyUnlocked: true)

        // Rebalance only when the monitor set changed (count or arrangement) — e.g. reconnecting
        // identical DisplayLink panels in a different layout. Never rebalance when nothing changed.
        if config.autoMoveWorkspacesOnMonitorConnect && signature != lastMonitorSignature {
            runDetached("screenParametersChanged") {
                try await runSession(.globalObserver("autoMoveWorkspaces"), token) {
                    gcMonitors() // the refresh that would do it is only requested so far
                    autoMoveWorkspacesToAssignedMonitors()
                }
            }
        }
        lastMonitorSignature = signature
    }

    /// Not private: covered directly by `MonitorIdentityTest`.
    @MainActor
    static func monitorSetSignature() -> String {
        sortedMonitors
            // The UUID is the only stable per-panel identity. `name` is macOS `localizedName`, whose
            // "(1)"/"(2)" suffixes are handed out by connection order — so two identical panels that
            // swap enumeration order across a DisplayLink flap produced an *unchanged* signature and
            // no rebalance, leaving workspaces on the wrong physical screens.
            .map { "\($0.fingerprint?.displayUUID ?? $0.name)|\($0.rect.topLeftX),\($0.rect.topLeftY),\($0.rect.width),\($0.rect.height)" }
            .joined(separator: ";")
    }
}
