@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspaceCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseWorkspaceCommand() {
        testParseCommandFail("workspace my mail", msg: "ERROR: Unknown argument 'mail'")
        testParseCommandFail("workspace 'my mail'", msg: "ERROR: Whitespace characters are forbidden in workspace names")
        assertEquals(parseCommand("workspace").errorOrNil, "ERROR: Argument '(<workspace>|next|prev)' is mandatory")
        testParseCommandSucc("workspace next", WorkspaceCmdArgs(target: .relative(.next)))
        testParseCommandSucc("workspace --auto-back-and-forth W", WorkspaceCmdArgs(target: .direct(.parse("W").getOrDie()), autoBackAndForth: true))
        assertEquals(parseCommand("workspace --wrap-around W").errorOrNil, "--wrap-around requires using (next|prev) argument")
        assertEquals(parseCommand("workspace --auto-back-and-forth next").errorOrNil, "--auto-back-and-forth is incompatible with (next|prev)")
        testParseCommandSucc("workspace next --wrap-around", WorkspaceCmdArgs(target: .relative(.next), wrapAround: true))
        testParseCommandSucc("workspace --wrap-around --skip-empty next", WorkspaceCmdArgs(target: .relative(.next), wrapAround: true, skipEmpty: true))
        assertEquals(parseCommand("workspace --skip-empty W").errorOrNil, "--skip-empty requires using (next|prev) argument")
    }

    /// `alt-n`/`alt-p` with five declared workspaces, two of them in use: the empty ones are passed over.
    func testSkipEmptyGoesToTheNextWorkspaceWithWindows() {
        config.persistentWorkspaces = ["1", "2", "3", "4", "5"]
        Workspace.garbageCollectUnusedWorkspaces()
        TestWindow.new(id: 9401, parent: Workspace.get(byName: "4").rootTilingContainer)
        XCTAssertTrue(Workspace.get(byName: "1").focusWorkspace()) // empty itself: the start still counts

        func step(_ isNext: Bool) -> String? {
            getNextPrevWorkspace(current: focus.workspace, isNext: isNext, wrapAround: true, stdin: "", target: focus, skipEmpty: true)?.name
        }
        assertEquals(step(true), "4")
        assertEquals(step(false), "4") // wraps past 5, 3 and 2: 4 is the only other one with windows

        // Without the flag nothing changes: every declared workspace is a stop.
        assertEquals(getNextPrevWorkspace(current: focus.workspace, isNext: true, wrapAround: true, stdin: "", target: focus)?.name, "2")
    }
}
