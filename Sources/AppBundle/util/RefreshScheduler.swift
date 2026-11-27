import AppKit
import Common

/// What a refresh was asked to do. Requests made while one is waiting merge into it.
struct RefreshRequest {
    var event: RefreshSessionEvent
    var screenIsDefinitelyUnlocked: Bool
    var optimisticallyPreLayoutWorkspaces: Bool

    mutating func merge(_ newer: RefreshRequest) {
        // `.startup` is what makes a refresh consult `WorkspaceMemory`. Losing the tag to whichever
        // event came next sent a window whose app answered late to the focused workspace.
        if !event.isStartup { event = newer.event }
        screenIsDefinitelyUnlocked = screenIsDefinitelyUnlocked || newer.screenIsDefinitelyUnlocked
        optimisticallyPreLayoutWorkspaces = optimisticallyPreLayoutWorkspaces || newer.optimisticallyPreLayoutWorkspaces
    }
}

/// At most one refresh running and one waiting. Bursts of accessibility events coalesce into a single
/// refresh after a short fixed delay, so we lay out once instead of per event.
///
/// An event never cancels a running refresh. It used to, and a 3-20 Hz stream could then kill every
/// refresh before it finished -- measured with a 400ms refresh under a 10ms stream, 12 started and none
/// completed -- and only the last event's flags survived. A session still cancels a running refresh, on
/// purpose: a hotkey must not wait for one. No refresh starts while a session is running or queued; the
/// session requests one at its end.
@MainActor
final class RefreshScheduler {
    private let delay: Duration
    private let abandonAfter: Duration
    private let run: @MainActor (RefreshRequest) async -> Void

    private var pending: RefreshRequest?
    private var timer: Task<Void, Never>?
    private var running: (id: Int, task: Task<Void, Never>, since: ContinuousClock.Instant)?
    private var nextRunId = 0
    /// Start time of each session that has not ended, by the token `sessionWillStart` handed out.
    ///
    /// Not a counter. A session whose await never comes back -- an app that stops answering, typically
    /// right after the Mac wakes from sleep -- never reaches its `sessionDidEnd`. `sessionGate` lets the
    /// next session in after its deadline, but a counter stayed above zero for the life of the process,
    /// and with it no refresh ever started again: windows that went away during sleep never came back,
    /// new windows were never detected, and every workspace switch moved nothing on screen.
    private var sessionsInFlight: [Int: ContinuousClock.Instant] = [:]
    private var nextSessionId = 0

    init(delay: Duration = .milliseconds(50), abandonAfter: Duration = .seconds(10), run: @escaping @MainActor (RefreshRequest) async -> Void) {
        self.delay = delay
        self.abandonAfter = abandonAfter
        self.run = run
    }

    func request(_ request: RefreshRequest) {
        if pending == nil { pending = request } else { pending?.merge(request) }
        restartTimer()
    }

    /// For quitting: what is already running must not write another frame.
    func cancelRunningRefresh() { running?.task.cancel() }

    /// Pass the returned token to `sessionDidEnd`.
    func sessionWillStart() -> Int {
        let id = nextSessionId
        nextSessionId &+= 1
        sessionsInFlight[id] = .now
        timer?.cancel()
        timer = nil
        running?.task.cancel()
        return id
    }

    func sessionDidEnd(_ id: Int) {
        sessionsInFlight.removeValue(forKey: id)
        if pending != nil { restartTimer() }
    }

    /// Same deadline as a refresh and as `sessionGate`: past it, a session is wedged, not slow.
    private func forgetWedgedSessions() {
        let now = ContinuousClock.now
        let wedged = sessionsInFlight.filter { now - $0.value > abandonAfter }.keys
        if wedged.isEmpty { return }
        AppLog.session.error("ignoring \(wedged.count, privacy: .public) session(s) that did not finish in time")
        for id in wedged { sessionsInFlight.removeValue(forKey: id) }
    }

    private func restartTimer() {
        timer?.cancel()
        timer = nil
        forgetWedgedSessions()
        if let oldest = sessionsInFlight.values.min() {
            // `sessionDidEnd` restarts it. This wakes up only for a session that never ends.
            timer = Task { [abandonAfter] in
                try? await Task.sleep(until: oldest + abandonAfter + .milliseconds(1), clock: .continuous)
                if Task.isCancelled { return }
                timer = nil
                restartTimer()
            }
            return
        }
        timer = Task { [delay] in
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return }
            timer = nil
            startIfIdle()
        }
    }

    private func startIfIdle() {
        // An await that never comes back must not end all refreshes for the life of the process, which
        // cancelling on every event used to rule out. A refresh only reaches this age if it is wedged:
        // each AX read is bounded by `axMessagingTimeout`, and a timed-out app is skipped for the pass.
        if let stale = running, ContinuousClock.now - stale.since > abandonAfter {
            AppLog.session.error("abandoning a refresh that did not finish in time")
            stale.task.cancel()
            running = nil
        }
        guard sessionsInFlight.isEmpty, running == nil, let request = pending else { return }
        pending = nil
        let id = nextRunId
        nextRunId &+= 1
        running = (id, Task { [run] in
            await run(request)
            guard running?.id == id else { return } // abandoned; the newer refresh owns the slot
            running = nil
            if timer == nil { startIfIdle() } // what arrived meanwhile has waited out its delay
        }, ContinuousClock.now)
    }
}

/// Sessions run one at a time, in the order they arrived.
///
/// A session suspends at every AX read, so two overlapping ones interleaved: two fast hotkeys could push
/// the first one's stale focus to macOS after the second's. No session awaits another (a nested
/// `runSession` would deadlock here), which `RefreshSchedulerTest` pins; callbacks spawn theirs detached.
@MainActor
final class FifoGate {
    private let abandonAfter: Duration
    private var holder: Int?
    private var nextTicket = 0
    private var waiters: [(ticket: Int, resume: CheckedContinuation<Void, Never>)] = []
    private var watchdog: Task<Void, Never>?

    init(abandonAfter: Duration = .seconds(10)) {
        self.abandonAfter = abandonAfter
    }

    func enter() async -> Int {
        let ticket = nextTicket
        nextTicket &+= 1
        if holder == nil {
            hold(ticket)
        } else {
            await withCheckedContinuation { waiters.append((ticket, $0)) }
        }
        return ticket
    }

    func leave(_ ticket: Int) {
        guard holder == ticket else { return } // the watchdog already moved on without it
        watchdog?.cancel()
        watchdog = nil
        holder = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            hold(next.ticket)
            next.resume.resume()
        }
    }

    private func hold(_ ticket: Int) {
        holder = ticket
        // Same reason as `RefreshScheduler`: without the gate, a wedged session only wedged itself.
        watchdog = Task { [abandonAfter] in
            try? await Task.sleep(for: abandonAfter)
            if Task.isCancelled { return }
            AppLog.session.error("a session held the gate past its deadline; letting the next one in")
            leave(ticket)
        }
    }
}
