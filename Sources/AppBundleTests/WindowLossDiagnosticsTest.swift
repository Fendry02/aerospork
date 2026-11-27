@testable import AppBundle
import Common
import XCTest

/// The records exist for one bug: live windows collected together when the screen locks, and never
/// detected again. They must stay rare (`AppLog`), so one window closing records nothing.
@MainActor
final class WindowLossDiagnosticsTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        WindowLossDiagnostics.resetForTests()
    }

    override func tearDown() async throws { WindowLossDiagnostics.resetForTests() }

    func testOneWindowClosingIsNotRecorded() {
        let root = Workspace.get(byName: "a").rootTilingContainer
        let window = TestWindow.new(id: 9101, parent: root)
        WindowLossDiagnostics.noteCollected([window], listedByApp: [:], frontmostBundleId: nil)
        assertEquals(WindowLossDiagnostics.lostWindowIdsForTests, [])
    }

    func testWindowsCollectedTogetherAreRecordedUntilTheyAreBack() {
        let root = Workspace.get(byName: "a").rootTilingContainer
        let a = TestWindow.new(id: 9102, parent: root)
        let b = TestWindow.new(id: 9103, parent: root)
        WindowLossDiagnostics.noteCollected([a, b], listedByApp: [:], frontmostBundleId: "com.apple.loginwindow")
        assertEquals(WindowLossDiagnostics.lostWindowIdsForTests, [9102, 9103])

        // Not registered again (test windows never are), so they stay recorded as lost.
        WindowLossDiagnostics.noteWindowsBack()
        assertEquals(WindowLossDiagnostics.lostWindowIdsForTests, [9102, 9103])
    }
}
