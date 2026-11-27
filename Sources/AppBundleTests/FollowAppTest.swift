@testable import AppBundle
import Common
import XCTest

/// `new-windows-follow-app`. A browser moved to workspace 5 opened its popups and modals on whichever
/// workspace the link was clicked from; with the option on they open beside the browser.
@MainActor
final class FollowAppTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testItIsOffByDefaultAndParses() {
        assertEquals(defaultConfig.newWindowsFollowApp, false)
        assertEquals(try? parseConfig("new-windows-follow-app = true").get().newWindowsFollowApp, true)
    }

    func testAnAppsFirstWindowOpensWhereYouAre() {
        let here = Workspace.get(byName: "here")
        assertNil(workspaceToFollowApp(appWindows: [], focusedWorkspace: here, lastFocusedWindowId: nil))
    }

    func testANewWindowOpensBesideTheAppOnAnotherWorkspace() {
        let here = Workspace.get(byName: "here")
        let five = Workspace.get(byName: "5")
        let browser = TestWindow.new(id: 9201, parent: five.rootTilingContainer)
        assertEquals(workspaceToFollowApp(appWindows: [browser], focusedWorkspace: here, lastFocusedWindowId: nil), five)
    }

    /// Finder or a terminal used on several workspaces keeps opening where you are.
    func testAnAppAlreadyHereKeepsOpeningHere() {
        let here = Workspace.get(byName: "here")
        let five = Workspace.get(byName: "5")
        let there = TestWindow.new(id: 9202, parent: five.rootTilingContainer)
        let local = TestWindow.new(id: 9203, parent: here.rootTilingContainer)
        assertNil(workspaceToFollowApp(appWindows: [there, local], focusedWorkspace: here, lastFocusedWindowId: 9202))
    }

    func testTheWorkspaceOfTheAppsLastFocusedWindowWins() {
        let here = Workspace.get(byName: "here")
        let two = Workspace.get(byName: "2")
        let five = Workspace.get(byName: "5")
        let older = TestWindow.new(id: 9204, parent: two.rootTilingContainer)
        let newer = TestWindow.new(id: 9205, parent: five.rootTilingContainer)
        assertEquals(workspaceToFollowApp(appWindows: [newer, older], focusedWorkspace: here, lastFocusedWindowId: 9204), two)
        // Without a known focus, the newest window decides, whatever the order of the input.
        assertEquals(workspaceToFollowApp(appWindows: [older, newer], focusedWorkspace: here, lastFocusedWindowId: nil), five)
        // A stale id (that window has closed) falls back the same way.
        assertEquals(workspaceToFollowApp(appWindows: [older, newer], focusedWorkspace: here, lastFocusedWindowId: 1), five)
    }

    func testFocusingAWindowRemembersItForItsApp() {
        let five = Workspace.get(byName: "5")
        let window = TestWindow.new(id: 9206, parent: five.rootTilingContainer)
        _ = window.focusWindow()
        assertEquals(lastFocusedWindowIdByPid[window.app.pid], 9206)
    }
}
