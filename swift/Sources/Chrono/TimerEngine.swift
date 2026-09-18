import Foundation

/// Every focus mode. Labels match the Python version exactly so old
/// `sessions.json` rows and the dashboard keep rendering.
enum FocusMode: Equatable {
    case pomodoro25
    case pomodoro50
    case infinite
    case custom(minutes: Int)

    /// Total countdown seconds, nil for infinite stopwatch.
    var totalSeconds: Int? {
        switch self {
        case .pomodoro25: return 25 * 60
        case .pomodoro50: return 50 * 60
        case .infinite: return nil
        case .custom(let m): return m * 60
        }
    }

    var label: String {
        switch self {
        case .pomodoro25: return "25 min 🍅"
        case .pomodoro50: return "50 min 🍅🍅"
        case .infinite: return "0 - ∞"
        case .custom(let m): return "⏱ \(m) min"
        }
    }
}

/// What the 1-second tick produced. The AppDelegate translates this
/// into store writes + notifications — the engine itself does no I/O,
/// so control flow stays explicit and testable.
enum TickOutcome: Equatable {
    case none
    /// Countdown reached zero. Caller must save + notify + reset title.
    case finished
}

/// Pure timer state machine. Main-thread only (driven by a 1s Timer).
///
/// Rules (confirmed with user, divergences from chrono.py noted):
/// - Launch = paused, sessionStart = nil (Python auto-started; Swift does NOT).
/// - Start is idempotent, never resets counters.
/// - Pause never saves.
/// - Stop saves-if->=5s + notifies, then clears session.
/// - Reset DISCARDS (Python silently saved; Swift does NOT — matches README).
/// - SetMode saves previous silently-if->=5s, switches, stays PAUSED
///   (Python auto-started the new mode; Swift waits for explicit Start).
/// - Finish clears sessionStart (Python left it stale -> double-count bug).
final class TimerEngine {
    private(set) var mode: FocusMode = .infinite
    private(set) var running: Bool = false
    private(set) var remaining: Int = 0          // countdown only
    private(set) var elapsedInfinite: Int = 0    // stopwatch only
    private(set) var sessionStart: Date? = nil   // nil = no unsaved work

    var modeTotalSeconds: Int { mode.totalSeconds ?? 0 }

    // MARK: - Derived

    /// Live duration that WOULD be saved if we stopped right now.
    func currentDuration() -> Int {
        if mode.totalSeconds == nil {
            return elapsedInfinite
        }
        return max(0, modeTotalSeconds - remaining)
    }

    func title() -> String {
        let prefix = running ? "▶" : "⏸"
        if mode.totalSeconds == nil {
            let h = elapsedInfinite / 3600
            let m = (elapsedInfinite % 3600) / 60
            let s = elapsedInfinite % 60
            if h > 0 {
                return String(format: "%@ ↑ %d:%02d:%02d", prefix, h, m, s)
            }
            return String(format: "%@ ↑ %02d:%02d", prefix, m, s)
        }
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%@ %02d:%02d", prefix, m, s)
    }

    // MARK: - Transitions (all explicit, no hidden side effects)

    /// Start/resume. Sets sessionStart on first start of a session.
    func start() {
        if running { return }                    // idempotent
        running = true
        if sessionStart == nil {
            sessionStart = Date()
        }
    }

    /// Pause. Never saves — symmetrical with Start.
    func pause() {
        if !running { return }                   // idempotent
        running = false
    }

    /// Stop session. Returns the duration to save (>=5s) or nil to discard.
    /// Always clears the session and resets counters.
    @discardableResult
    func stop(minimumSeconds: Int = 5) -> Int? {
        running = false
        defer { clearSessionAndResetCounters() }
        guard sessionStart != nil else { return nil }
        let d = currentDuration()
        return d >= minimumSeconds ? d : nil
    }

    /// Reset. ALWAYS discards (no save), clears session, resets counters.
    func reset() {
        running = false
        clearSessionAndResetCounters()
    }

    /// Switch mode. Returns previous-session duration to save silently (>=5s)
    /// or nil. New mode starts PAUSED with a clean session (sessionStart = nil
    /// until explicit Start — deliberate change from Python's auto-start).
    @discardableResult
    func setMode(_ newMode: FocusMode, minimumSeconds: Int = 5) -> (durationToSave: Int?, previousMode: FocusMode)? {
        var toSave: Int? = nil
        var prev: FocusMode? = nil
        if sessionStart != nil {
            let d = currentDuration()
            if d >= minimumSeconds {
                toSave = d
                prev = mode
            }
        }
        mode = newMode
        running = false
        elapsedInfinite = 0
        remaining = newMode.totalSeconds ?? 0
        sessionStart = nil
        if let p = prev, let d = toSave {
            return (d, p)
        }
        return nil
    }

    /// Advance one second. Returns .finished exactly once when a countdown
    /// hits zero; caller saves + notifies. Also clears session + resets
    /// remaining so a repeat press of Start begins fresh.
    func tick(minimumSeconds: Int = 5) -> (outcome: TickOutcome, durationToSave: Int?) {
        guard running else { return (.none, nil) }
        if mode.totalSeconds == nil {
            elapsedInfinite += 1
            return (.none, nil)
        }
        if remaining > 0 {
            remaining -= 1
            return (.none, nil)
        }
        // Countdown complete.
        running = false
        var toSave: Int? = nil
        if sessionStart != nil {
            let d = currentDuration()
            if d >= minimumSeconds { toSave = d }
        }
        // Reset for repeat + clear stale start (Python bug fix).
        remaining = modeTotalSeconds
        sessionStart = nil
        return (.finished, toSave)
    }

    // MARK: - Private

    private func clearSessionAndResetCounters() {
        if mode.totalSeconds == nil {
            elapsedInfinite = 0
        } else {
            remaining = modeTotalSeconds
        }
        sessionStart = nil
    }
}
