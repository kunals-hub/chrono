import AppKit
import Foundation

/// Menu-bar controller. Owns the status item, the TimerEngine, the dashboard
/// server, and all menu actions. Every control-flow transition goes through
/// TimerEngine so Start/Pause/Stop/Reset/SetMode/Tick can't drift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = TimerEngine()
    private let dashboard = DashboardServer()
    private var timer: Timer?

    private var item25: NSMenuItem!
    private var item50: NSMenuItem!
    private var itemInfinite: NSMenuItem!
    private var itemCustom: NSMenuItem!
    /// Last title pushed to the status item. While paused the title never
    /// changes, so skipping redundant sets avoids a CoreAnimation redraw +
    /// XPC round-trip to MenuBarAgent every second (was ~1% idle CPU).
    private var lastTitle: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Background agent: no Dock icon, no cmd+tab. (LSUIElement=true in
        // Info.plist is the primary mechanism; this is belt-and-braces.)
        NSApp.setActivationPolicy(.accessory)
        Notify.requestAuthorization()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .removalAllowed
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        buildMenu()
        updateTitle()

        // LAUNCH = paused (deliberate change from Python auto-start).
        // `chrono` makes the icon appear; nothing counts until explicit Start.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ note: Notification) {
        saveSilentlyCurrent()
        dashboard.shutdown()
        SingleInstance.releaseLock()
    }

    // MARK: - Menu (same options as chrono.py)

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "▶ Start", action: #selector(didStart), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⏸ Pause", action: #selector(didPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "⏹ Stop Session", action: #selector(didStop), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "↺ Reset", action: #selector(didReset), keyEquivalent: ""))
        menu.addItem(.separator())
        item25 = NSMenuItem(title: "🍅 25 min", action: #selector(didPick25), keyEquivalent: "")
        item50 = NSMenuItem(title: "🍅🍅 50 min", action: #selector(didPick50), keyEquivalent: "")
        itemCustom = NSMenuItem(title: "⏱ Custom...", action: #selector(didPickCustom), keyEquivalent: "")
        itemInfinite = NSMenuItem(title: "0 - ∞", action: #selector(didPickInfinite), keyEquivalent: "")
        menu.addItem(item25)
        menu.addItem(item50)
        menu.addItem(itemCustom)
        menu.addItem(itemInfinite)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "📊 Dashboard", action: #selector(didOpenDashboard), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(didQuit), keyEquivalent: "q"))
        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func updateTitle() {
        // Checkmark the active mode family (cheap; menu is hidden, no display).
        switch engine.mode {
        case .pomodoro25: item25.state = .on; item50.state = .off; itemInfinite.state = .off; itemCustom.state = .off
        case .pomodoro50: item25.state = .off; item50.state = .on; itemInfinite.state = .off; itemCustom.state = .off
        case .infinite: item25.state = .off; item50.state = .off; itemInfinite.state = .on; itemCustom.state = .off
        case .custom: item25.state = .off; item50.state = .off; itemInfinite.state = .off; itemCustom.state = .on
        }
        let t = engine.title()
        guard t != lastTitle else { return }
        lastTitle = t
        statusItem.button?.title = t
    }

    // MARK: - Tick

    private func tick() {
        let (outcome, duration) = engine.tick()
        if outcome == .finished {
            // Countdown hit zero: save-if->=5s (silent duration from engine),
            // notify Time's up, clear pending (engine already cleared its own).
            if let d = duration, let start = pendingSession {
                Store.saveSession(Store.makeSession(mode: start.mode, start: start.date, end: Date(), duration: d))
            }
            pendingSession = nil
            Notify.send(title: "Chrono", body: "🍅 Time's up! Great session — take a break")
        }
        updateTitle()
    }

    // MARK: - Pending session tracking
    //
    // TimerEngine holds sessionStart, but Store needs the wall-clock start +
    // mode label at save time. We mirror (startDate, modeLabel) here, set on
    // Start / cleared on Stop/Reset/Finish/SetMode — exactly mirroring the
    // engine's sessionStart lifecycle so the two can never drift.

    private var pendingSession: (date: Date, mode: String)?

    private func ensurePending() {
        if pendingSession == nil {
            pendingSession = (Date(), engine.mode.label)
        }
    }

    // MARK: - Actions

    @objc private func didStart() {
        ensurePending()
        engine.start()
        // If engine had no session (fresh launch / after stop), pending was just
        // created above with the CURRENT mode — correct.
        updateTitle()
    }

    @objc private func didPause() {
        engine.pause()
        updateTitle()
    }

    @objc private func didStop() {
        let modeLabel = pendingSession?.mode ?? engine.mode.label
        let startDate = pendingSession?.date ?? Date()
        if let duration = engine.stop() {
            Store.saveSession(Store.makeSession(mode: modeLabel, start: startDate, end: Date(), duration: duration))
            Notify.send(title: "Chrono", body: "🍅 Session saved! \(Store.fmt(duration)) of focus time recorded.")
        }
        pendingSession = nil
        updateTitle()
    }

    @objc private func didReset() {
        // DISCARD — no save (matches README, fixes Python contradiction).
        engine.reset()
        pendingSession = nil
        updateTitle()
    }

    @objc private func didPick25() { switchMode(to: .pomodoro25) }
    @objc private func didPick50() { switchMode(to: .pomodoro50) }
    @objc private func didPickInfinite() { switchMode(to: .infinite) }

    private func switchMode(to newMode: FocusMode) {
        // Save previous silently if >=5s.
        if let start = pendingSession {
            if let result = engine.setMode(newMode), let d = result.durationToSave {
                Store.saveSession(Store.makeSession(mode: start.mode, start: start.date, end: Date(), duration: d))
            }
        } else {
            _ = engine.setMode(newMode)
        }
        pendingSession = nil
        // Stays PAUSED until explicit Start (change from Python auto-start).
        updateTitle()
        refreshCustomLabel()
    }

    private func refreshCustomLabel() {
        if case .custom(let m) = engine.mode {
            itemCustom.title = "⏱ \(m) min ✓"
        } else {
            itemCustom.title = "⏱ Custom..."
        }
    }

    @objc private func didPickCustom() {
        let alert = NSAlert()
        alert.messageText = "Custom timer"
        alert.informativeText = "Enter minutes to focus:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "45"
        alert.accessoryView = field
        // Focus the input so the cursor lands there with "45" selected —
        // typing immediately replaces the default, no click needed.
        alert.window.initialFirstResponder = field
        // Show above menu-bar context even as accessory app.
        NSApp.activate(ignoringOtherApps: true)
        // Select-all must run after the window exists; initialFirstResponder
        // above forces window creation, so the field editor is ready.
        field.selectText(nil)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return } // Cancel -> no-op
        guard let minutes = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), minutes > 0 else {
            let err = NSAlert()
            err.messageText = "Invalid"
            err.informativeText = "Enter a whole number of minutes."
            err.runModal()
            return
        }
        switchMode(to: .custom(minutes: minutes))
    }

    @objc private func didOpenDashboard() {
        dashboard.open()
    }

    @objc private func didQuit() {
        saveSilentlyCurrent()
        dashboard.shutdown()
        SingleInstance.releaseLock()
        NSApp.terminate(nil)
    }

    // MARK: - Silent save (mode switch / quit)

    private func saveSilentlyCurrent() {
        guard let start = pendingSession else { return }
        guard engine.sessionStart != nil else { pendingSession = nil; return }
        let duration = engine.currentDuration()
        _ = engine.stop() // resets counters + clears engine session; returns same duration
        pendingSession = nil
        guard duration >= 5 else { return } // <5s discard
        Store.saveSession(Store.makeSession(mode: start.mode, start: start.date, end: Date(), duration: duration))
    }
}
