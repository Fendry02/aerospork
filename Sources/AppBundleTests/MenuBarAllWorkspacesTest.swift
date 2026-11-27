@testable import AppBundle
import Common
import XCTest

/// `menu-bar-shows-all-workspaces`: a chip for every workspace, so you can see where your windows are
/// without switching to each one.
@MainActor
final class MenuBarAllWorkspacesTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testItIsOffByDefaultAndParses() {
        assertEquals(defaultConfig.menuBarShowsAllWorkspaces, false)
        assertEquals(try? parseConfig("menu-bar-shows-all-workspaces = true").get().menuBarShowsAllWorkspaces, true)
    }

    func testEachWorkspaceGetsTheLookOfItsState() {
        let one = Workspace.get(byName: "1")
        let two = Workspace.get(byName: "2")
        let three = Workspace.get(byName: "3")
        TestWindow.new(id: 9301, parent: two.rootTilingContainer)
        _ = one.focusWorkspace()

        let items = trayItemsForAllWorkspaces([three, two, one], focused: one)
        assertEquals(items.map(\.name), ["1", "2", "3"]) // the order `workspace next` walks, not the input's
        assertEquals(items.map(\.look), [.focused, .occupied, .empty])
        assertEquals(items.map(\.isActive), [true, false, false])
    }

    /// Ten sorts after nine, as `workspace next` walks them: numbers in numeric order.
    func testNumbersSortNumerically() {
        let names = trayItemsForAllWorkspaces(["10", "9", "1"].map { Workspace.get(byName: $0) }, focused: Workspace.get(byName: "1"))
            .map(\.name)
        assertEquals(names, ["1", "9", "10"])
    }

    /// The old initializer still means what it meant: one chip per monitor, filled or outlined.
    func testThePerMonitorChipsKeepTheirLooks() {
        assertEquals(TrayItem(type: .workspace, name: "1", isActive: true).look, .focused)
        assertEquals(TrayItem(type: .workspace, name: "2", isActive: false).look, .visible)
    }
}
