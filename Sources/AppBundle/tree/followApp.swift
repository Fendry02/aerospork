import Common

/// `new-windows-follow-app`: the workspace a new window of an app with windows elsewhere belongs on.
///
/// Without it, a window AeroSpork has never seen opens on the focused workspace. That is right for an
/// app's first window and wrong for the rest of them: a browser moved to workspace 5 opened its sign-in
/// popup, its modal and its next window on whichever workspace the link was clicked from. The usual
/// workaround, an `on-window-detected` rule per app, sends every window of the app to one fixed
/// workspace, so it cannot follow the app once you move it.
///
/// - The app already has a window on the focused workspace: nil, so the window opens here, as before.
///   Finder or a terminal used on several workspaces keeps opening where you are.
/// - Otherwise the workspace of the app's window that had focus last.
/// - Otherwise the workspace of its newest window (highest id), so the answer does not depend on
///   dictionary order.
/// - No other window: nil. The first window of an app opens where you are, and rules still apply.
///
/// `appWindows` is every registered window of the app, without the new one.
@MainActor
func workspaceToFollowApp(appWindows: [Window], focusedWorkspace: Workspace, lastFocusedWindowId: UInt32?) -> Workspace? {
    if appWindows.isEmpty { return nil }
    if appWindows.contains(where: { $0.nodeWorkspace == focusedWorkspace }) { return nil }
    if let lastFocusedWindowId,
       let last = appWindows.first(where: { $0.windowId == lastFocusedWindowId }),
       let workspace = last.nodeWorkspace
    {
        return workspace
    }
    return appWindows.sorted { $0.windowId > $1.windowId }.lazy.compactMap(\.nodeWorkspace).first
}
