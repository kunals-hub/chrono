#!/usr/bin/env python3
"""
Chrono Timer — Menu Bar App for macOS
- 25 min, 50 min, ∞ (infinite/stopwatch), or Custom (any minutes)
- Live countdown/up in menu bar (1-second updates, no cmd+tab clutter)
- Session data saved to JSON
- Browser dashboard for stats
"""

import rumps
import json
import threading
import webbrowser
import os
import sys
import signal
import subprocess
from datetime import datetime, date, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# --- Config ---
DATA_DIR = Path(__file__).parent / "data"
SESSIONS_FILE = DATA_DIR / "sessions.json"
DASHBOARD_PORT = 8765
LOCK_FILE = Path("/tmp/chrono.lock")

MODES = {
    "25 min 🍅": 25 * 60,
    "50 min 🍅🍅": 50 * 60,
    "0 - ∞": None,
}


# ─── Single instance lock ───────────────────────────────────────
def acquire_lock():
    """Ensure only one instance runs."""
    import fcntl

    try:
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_WRONLY)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Write our PID so we can kill it later
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        return fd
    except (OSError, IOError):
        # Another instance is running — quit this one
        try:
            # Try to signal the existing instance to open its dashboard
            if LOCK_FILE.exists():
                existing_pid = int(LOCK_FILE.read_text().strip())
                os.kill(existing_pid, signal.SIGUSR1)
        except Exception:
            pass
        sys.exit(0)


def release_lock(fd):
    """Release the single instance lock."""
    import fcntl

    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
        LOCK_FILE.unlink(missing_ok=True)
    except Exception:
        pass


# ─── Data helpers ───────────────────────────────────────────────
def load_sessions() -> list:
    if SESSIONS_FILE.exists():
        with open(SESSIONS_FILE, "r") as f:
            return json.load(f)
    return []


def save_session(session_data: dict):
    DATA_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    sessions.append(session_data)
    with open(SESSIONS_FILE, "w") as f:
        json.dump(sessions, f, indent=2)


def fmt(seconds: int) -> str:
    """Format seconds as Xm Ys or Xh Ym."""
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h {m}m"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


# ─── Dashboard server ──────────────────────────────────────────
def _dashboard_handler(sessions: list):
    """Build an HTTP request handler class bound to the given sessions list."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self.send_response(200)
                self.send_header("Content-type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(_render_dashboard(sessions).encode())
            elif self.path == "/api/sessions":
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(sessions).encode())
            else:
                self.send_response(404)
                self.end_headers()

        def log_message(self, format, *args):
            pass  # silence logging

    return Handler


class DashboardServer:
    def __init__(self):
        self.server = None
        self._thread = None

    def start(self):
        if self.server:
            return
        sessions = load_sessions()
        handler = _dashboard_handler(sessions)
        self.server = HTTPServer(("127.0.0.1", DASHBOARD_PORT), handler)
        self._thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self._thread.start()

    def open(self):
        self.start()
        webbrowser.open(f"http://localhost:{DASHBOARD_PORT}")

    def shutdown(self):
        if self.server:
            self.server.shutdown()


# ─── Dashboard HTML ────────────────────────────────────────────
def _render_dashboard(sessions: list) -> str:
    today = date.today()
    today_str = today.isoformat()

    # Today's sessions
    today_sessions = [s for s in sessions if s["date"] == today_str]
    today_total = sum(s["duration"] for s in today_sessions)
    today_count = len(today_sessions)

    # Last 7 days
    week_bars = []
    max_day = 1  # avoid div-by-zero
    for i in range(7):
        d = today - timedelta(days=6 - i)
        d_str = d.isoformat()
        d_total = sum(s["duration"] for s in sessions if s["date"] == d_str)
        max_day = max(max_day, d_total)
        week_bars.append({"date": d_str, "label": d.strftime("%a"), "total": d_total})

    # Mode totals
    mode_totals = {}
    for s in sessions:
        m = s["mode"]
        mode_totals[m] = mode_totals.get(m, 0) + s["duration"]
    grand_total = sum(mode_totals.values())

    # Build mode breakdown rows
    mode_rows = ""
    mode_colors = {"25 min 🍅": "#ff6b6b", "50 min 🍅🍅": "#ffa94d", "0 - ∞": "#74c0fc"}
    for m, total in sorted(mode_totals.items(), key=lambda x: -x[1]):
        pct = (total / grand_total * 100) if grand_total else 0
        color = mode_colors.get(m, "#868e96")
        mode_rows += f"""
        <div class="mode-row">
            <span class="mode-dot" style="background:{color}"></span>
            <span class="mode-name">{m}</span>
            <span class="mode-bar-wrap"><span class="mode-bar" style="width:{pct}%;background:{color}"></span></span>
            <span class="mode-time">{fmt(total)}</span>
        </div>"""

    # Build week bars
    week_html = ""
    for b in week_bars:
        h = int((b["total"] / max_day) * 140) if max_day else 0
        is_today = b["date"] == today_str
        week_html += f"""
        <div class="week-day{' today' if is_today else ''}">
            <div class="week-bar-wrap"><div class="week-bar" style="height:{h}px"></div></div>
            <div class="week-label">{b['label']}</div>
            <div class="week-time">{fmt(b['total']) if b['total'] else ''}</div>
        </div>"""

    # Recent sessions list
    recent = sorted(sessions, key=lambda s: s["end_time"], reverse=True)[:20]
    recent_rows = ""
    for s in recent:
        recent_rows += f"""
        <div class="recent-row">
            <span class="recent-date">{s['date']}</span>
            <span class="recent-mode">{s['mode']}</span>
            <span class="recent-time">{s['start_time']} → {s['end_time']}</span>
            <span class="recent-dur">{s.get('duration_formatted', fmt(s['duration']))}</span>
        </div>"""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Chrono Dashboard</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#e6edf3;min-height:100vh;padding:40px}}
.container{{max-width:900px;margin:0 auto}}
h1{{font-size:28px;font-weight:700;margin-bottom:8px;display:flex;align-items:center;gap:10px}}
.subtitle{{color:#8b949e;font-size:14px;margin-bottom:32px}}
.stats-grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin-bottom:32px}}
.stat-card{{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:20px;text-align:center}}
.stat-card .label{{color:#8b949e;font-size:12px;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}}
.stat-card .value{{font-size:32px;font-weight:700;color:#f0f6fc}}
.stat-card .sub{{color:#8b949e;font-size:12px;margin-top:4px}}
.card{{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:24px;margin-bottom:20px}}
.card h2{{font-size:16px;font-weight:600;margin-bottom:16px;color:#f0f6fc}}
.week-chart{{display:flex;align-items:flex-end;justify-content:space-between;gap:8px;height:200px;padding-top:10px}}
.week-day{{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:flex-end}}
.week-bar-wrap{{flex:1;display:flex;align-items:flex-end;width:100%;justify-content:center}}
.week-bar{{width:28px;border-radius:6px 6px 2px 2px;background:linear-gradient(180deg,#2d8a4e,#2d8a4e80);transition:height .3s}}
.week-day.today .week-bar{{background:linear-gradient(180deg,#ff6b6b,#ff6b6b80)}}
.week-label{{font-size:11px;color:#8b949e;margin-top:6px}}
.week-day.today .week-label{{color:#ff6b6b;font-weight:600}}
.week-time{{font-size:10px;color:#484f58;margin-top:2px}}
.mode-row{{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid #21262d}}
.mode-row:last-child{{border-bottom:none}}
.mode-dot{{width:10px;height:10px;border-radius:50%;flex-shrink:0}}
.mode-name{{width:140px;font-size:14px}}
.mode-bar-wrap{{flex:1;height:8px;background:#21262d;border-radius:4px;overflow:hidden}}
.mode-bar{{display:block;height:100%;border-radius:4px;transition:width .3s}}
.mode-time{{width:70px;text-align:right;font-size:14px;font-weight:600;color:#f0f6fc}}
.recent-row{{display:flex;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid #21262d;font-size:13px}}
.recent-row:last-child{{border-bottom:none}}
.recent-date{{width:90px;color:#8b949e;flex-shrink:0}}
.recent-mode{{width:120px;flex-shrink:0}}
.recent-time{{flex:1;color:#8b949e}}
.recent-dur{{width:70px;text-align:right;font-weight:600;color:#f0f6fc}}
@media(max-width:600px){{.stats-grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<div class="container">
    <h1>🍅 Chrono Dashboard</h1>
    <p class="subtitle">Your focus data, locally stored</p>

    <div class="stats-grid">
        <div class="stat-card">
            <div class="label">Today</div>
            <div class="value">{fmt(today_total)}</div>
            <div class="sub">{today_count} session{'s' if today_count != 1 else ''}</div>
        </div>
        <div class="stat-card">
            <div class="label">Total Focus</div>
            <div class="value">{fmt(grand_total)}</div>
            <div class="sub">all time</div>
        </div>
        <div class="stat-card">
            <div class="label">Total Sessions</div>
            <div class="value">{len(sessions)}</div>
            <div class="sub">completed</div>
        </div>
    </div>

    <div class="card">
        <h2>📅 This Week</h2>
        <div class="week-chart">
            {week_html}
        </div>
    </div>

    <div class="card">
        <h2>🍅 By Mode</h2>
        {mode_rows if mode_rows else '<p style="color:#8b949e;font-size:14px">No sessions yet — start your first focus session!</p>'}
    </div>

    <div class="card">
        <h2>🕐 Recent Sessions</h2>
        {recent_rows if recent_rows else '<p style="color:#8b949e;font-size:14px">No sessions yet</p>'}
    </div>
</div>
</body>
</html>"""


# ─── Main App ──────────────────────────────────────────────────
class ChronoApp(rumps.App):
    def __init__(self):
        super().__init__("Chrono", quit_button=None)

        self.current_mode = "0 - ∞"
        self.remaining = MODES[self.current_mode]
        self.running = True
        self.elapsed_infinite = 0
        self.session_start_time = datetime.now()
        self.mode_total_seconds = 0  # for custom modes

        self.dashboard = DashboardServer()
        self.timer = rumps.Timer(self._tick, 1)
        self.timer.start()

        self.menu = [
            rumps.MenuItem("▶ Start", callback=self.start_timer),
            rumps.MenuItem("⏸ Pause", callback=self.pause_timer),
            rumps.MenuItem("⏹ Stop Session", callback=self.stop_session),
            rumps.MenuItem("↺ Reset", callback=self.reset_timer),
            None,
            rumps.MenuItem("🍅 25 min", callback=lambda _: self.set_mode("25 min 🍅", 25 * 60)),
            rumps.MenuItem("🍅🍅 50 min", callback=lambda _: self.set_mode("50 min 🍅🍅", 50 * 60)),
            rumps.MenuItem("⏱ Custom...", callback=self.custom_timer_dialog),
            rumps.MenuItem("0 - ∞", callback=lambda _: self.set_mode("0 - ∞", None)),
            None,
            rumps.MenuItem("📊 Dashboard", callback=lambda _: self.dashboard.open()),
            None,
            rumps.MenuItem("Quit", callback=self.quit_app),
        ]
        self._update_title()

    # ── Timer logic ──
    def _tick(self, _):
        if not self.running:
            return
        if self.current_mode == "0 - ∞":
            self.elapsed_infinite += 1
        else:
            if self.remaining > 0:
                self.remaining -= 1
            else:
                self.running = False
                self._save_session()
                self.remaining = self.mode_total_seconds  # reset for repeat
                rumps.notification("Chrono", "🍅 Time's up!", "Great session — take a break")
        self._update_title()

    def _update_title(self):
        if self.current_mode == "0 - ∞":
            m, s = divmod(self.elapsed_infinite, 60)
            h, m = divmod(m, 60)
            prefix = "▶" if self.running else "⏸"
            self.title = f"{prefix} ↑ {h}:{m:02d}:{s:02d}" if h else f"{prefix} ↑ {m:02d}:{s:02d}"
        else:
            m, s = divmod(self.remaining, 60)
            prefix = "▶" if self.running else "⏸"
            self.title = f"{prefix} {m:02d}:{s:02d}"

    # ── Data ──
    def _save_session(self):
        if self.session_start_time is None:
            return

        end_time = datetime.now()
        if self.current_mode == "0 - ∞":
            duration = self.elapsed_infinite
        else:
            duration = self.mode_total_seconds - self.remaining

        if duration < 5:
            return

        save_session({
            "date": date.today().isoformat(),
            "mode": self.current_mode,
            "start_time": self.session_start_time.strftime("%H:%M:%S"),
            "end_time": end_time.strftime("%H:%M:%S"),
            "duration": duration,
            "duration_formatted": fmt(duration),
        })

    # ── Callbacks ──
    def start_timer(self, _):
        self.running = True
        if self.session_start_time is None:
            self.session_start_time = datetime.now()
        self._update_title()

    def pause_timer(self, _):
        self.running = False
        self._update_title()

    def stop_session(self, _):
        self.running = False
        if self.session_start_time is not None:
            if self.current_mode == "0 - ∞":
                duration = self.elapsed_infinite
            else:
                duration = self.mode_total_seconds - self.remaining
            
            if duration >= 5:
                self._save_session()
                rumps.notification("Chrono", "🍅 Session saved!", f"{fmt(duration)} of focus time recorded.")
        
        # Reset to mode default
        if self.current_mode == "0 - ∞":
            self.elapsed_infinite = 0
        else:
            self.remaining = self.mode_total_seconds
        self.session_start_time = None
        self._update_title()

    def reset_timer(self, _):
        self.running = False
        self._save_session()
        if self.current_mode == "0 - ∞":
            self.elapsed_infinite = 0
        else:
            self.remaining = self.mode_total_seconds
        self.session_start_time = None
        self._update_title()

    def set_mode(self, mode, seconds):
        self._save_session()
        self.current_mode = mode
        self.running = True
        self.elapsed_infinite = 0
        self.remaining = seconds if seconds else 0
        self.mode_total_seconds = seconds if seconds else 0
        self.session_start_time = datetime.now()
        self._update_title()

    def custom_timer_dialog(self, _):
        # Use osascript for input dialog since rumps.alert doesn't support text input
        try:
            result = subprocess.run(
                ['osascript', '-e', 'text returned of (display dialog "Enter minutes to focus:" default answer "45" buttons {"Cancel", "Start"} default button "Start")'],
                capture_output=True, text=True, timeout=30
            )
            if result.returncode == 0:
                minutes_str = result.stdout.strip()
                minutes = int(minutes_str)
                if minutes > 0:
                    self.set_mode(f"⏱ {minutes} min", minutes * 60)
                else:
                    rumps.alert(title="Invalid", message="Minutes must be positive.")
            else:
                # User cancelled
                return
        except (ValueError, subprocess.TimeoutExpired):
            rumps.alert(title="Invalid", message="Enter a whole number of minutes.")

    def quit_app(self, _):
        self._save_session()
        self.dashboard.shutdown()
        rumps.quit_application()


if __name__ == "__main__":
    lock_fd = acquire_lock()
    try:
        ChronoApp().run()
    finally:
        release_lock(lock_fd)
