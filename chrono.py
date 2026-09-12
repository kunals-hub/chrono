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
def _resolve_data_dir() -> Path:
    """User data lives OUTSIDE the .app bundle so rebuilds never wipe it.
    macOS convention: ~/Library/Application Support/Chrono.
    CHRONO_DATA_DIR env overrides (used by tests)."""
    override = os.environ.get("CHRONO_DATA_DIR")
    if override:
        d = Path(override).expanduser()
        d.mkdir(parents=True, exist_ok=True)
        return d
    d = Path.home() / "Library" / "Application Support" / "Chrono"
    d.mkdir(parents=True, exist_ok=True)
    _migrate_legacy_data(d)
    return d


def _migrate_legacy_data(dest: Path):
    """One-time move from pre-fix locations (inside .app bundles / repo dir).
    Only copies files the destination doesn't already have — never overwrites."""
    candidates = [
        Path(__file__).parent / "data",  # running from source, or old bundle layout
    ]
    dist = Path(__file__).parent.parent.parent  # Chrono.app/Contents/Resources -> dist/
    if dist.name == "dist":
        for app in ("Chrono.app", "Kairos.app"):
            candidates.append(dist / app / "Contents" / "Resources" / "data")
    else:
        here = Path(__file__).parent
        candidates.append(here / "dist" / "Chrono.app" / "Contents" / "Resources" / "data")
        candidates.append(here / "dist" / "Kairos.app" / "Contents" / "Resources" / "data")
    for src in candidates:
        if not src.exists() or src.resolve() == dest.resolve():
            continue
        for name in ("sessions.json", "summaries.json"):
            s, t = src / name, dest / name
            if s.is_file() and not t.exists():
                try:
                    t.write_bytes(s.read_bytes())
                except OSError:
                    pass
        src_arch, dest_arch = src / "archive", dest / "archive"
        if src_arch.is_dir():
            dest_arch.mkdir(exist_ok=True)
            for f in src_arch.glob("*.json"):
                t = dest_arch / f.name
                if not t.exists():
                    try:
                        t.write_bytes(f.read_bytes())
                    except OSError:
                        pass


DATA_DIR = _resolve_data_dir()
SESSIONS_FILE = DATA_DIR / "sessions.json"
ARCHIVE_DIR = DATA_DIR / "archive"
SUMMARIES_FILE = DATA_DIR / "summaries.json"
DASHBOARD_PORT = 8765
LOCK_FILE = Path("/tmp/chrono.lock")
# Raw session detail kept locally; older months auto-archived.
# Summaries always cover all-time so old data is never lost.
ARCHIVE_AFTER_DAYS = 90

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
# Storage tiers (Forest-style, all local & permanent):
#   data/sessions.json    — raw detail, last ~90 days
#   data/archive/YYYY-MM.json — raw detail for older months (never deleted)
#   data/summaries.json   — daily / weekly / monthly rollups, all-time
def load_sessions() -> list:
    """Recent raw sessions (hot file)."""
    if SESSIONS_FILE.exists():
        try:
            with open(SESSIONS_FILE, "r") as f:
                data = json.load(f)
                return data if isinstance(data, list) else []
        except (json.JSONDecodeError, OSError):
            return []
    return []


def load_all_sessions() -> list:
    """Recent + every archived month. Source for dashboard totals."""
    all_s = load_sessions()
    if ARCHIVE_DIR.exists():
        for f in sorted(ARCHIVE_DIR.glob("*.json")):
            try:
                with open(f, "r") as fh:
                    data = json.load(fh)
                    if isinstance(data, list):
                        all_s.extend(data)
            except (json.JSONDecodeError, OSError):
                continue
    return all_s


def _week_key(d: date) -> str:
    iso = d.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def build_summaries(sessions: list) -> dict:
    daily: dict = {}
    weekly: dict = {}
    monthly: dict = {}
    for s in sessions:
        try:
            dur = int(s.get("duration", 0))
            d = date.fromisoformat(s["date"])
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        dk = d.isoformat()
        wk = _week_key(d)
        mk = d.strftime("%Y-%m")
        for store, key in ((daily, dk), (weekly, wk), (monthly, mk)):
            entry = store.setdefault(key, {"total": 0, "sessions": 0})
            entry["total"] += dur
            entry["sessions"] += 1
    return {"daily": daily, "weekly": weekly, "monthly": monthly}


def run_maintenance() -> dict:
    """Archive sessions older than ARCHIVE_AFTER_DAYS into archive/YYYY-MM.json
    and rebuild summaries.json. Old daily detail is compacted into monthly
    files — totals are never lost."""
    DATA_DIR.mkdir(exist_ok=True)
    ARCHIVE_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    if not sessions:
        # Still ensure summaries exist from archives
        existing = load_all_sessions()
        summaries = build_summaries(existing)
        with open(SUMMARIES_FILE, "w") as f:
            json.dump(summaries, f, indent=2)
        return summaries

    cutoff = date.today() - timedelta(days=ARCHIVE_AFTER_DAYS)
    keep: list = []
    old_by_month: dict = {}
    for s in sessions:
        try:
            d = date.fromisoformat(s.get("date", ""))
        except ValueError:
            keep.append(s)
            continue
        if d < cutoff:
            old_by_month.setdefault(d.strftime("%Y-%m"), []).append(s)
        else:
            keep.append(s)

    for month, items in old_by_month.items():
        dest = ARCHIVE_DIR / f"{month}.json"
        merged = list(items)
        if dest.exists():
            try:
                with open(dest, "r") as fh:
                    prior = json.load(fh)
                    if isinstance(prior, list):
                        merged = prior + items
            except (json.JSONDecodeError, OSError):
                pass
        with open(dest, "w") as fh:
            json.dump(merged, fh, indent=2)

    if old_by_month:
        with open(SESSIONS_FILE, "w") as f:
            json.dump(keep, f, indent=2)

    summaries = build_summaries(load_all_sessions())
    with open(SUMMARIES_FILE, "w") as f:
        json.dump(summaries, f, indent=2)
    return summaries


def save_session(session_data: dict):
    DATA_DIR.mkdir(exist_ok=True)
    sessions = load_sessions()
    sessions.append(session_data)
    with open(SESSIONS_FILE, "w") as f:
        json.dump(sessions, f, indent=2)
    # Keep tiers tidy on every save (cheap at this scale)
    try:
        run_maintenance()
    except Exception:
        pass


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
def _dashboard_handler():
    """Build an HTTP request handler that loads fresh data per request
    (recent + archive), so the dashboard never shows stale totals."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path in ("/", "/index.html"):
                sessions = load_all_sessions()
                self.send_response(200)
                self.send_header("Content-type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(_render_dashboard(sessions).encode())
            elif self.path == "/api/sessions":
                sessions = load_all_sessions()
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
        handler = _dashboard_handler()
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
    today_sessions = [s for s in sessions if s.get("date") == today_str]
    today_total = sum(int(s.get("duration", 0)) for s in today_sessions)
    today_count = len(today_sessions)

    # This week (Mon–Sun) + this month + all-time
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)
    month_prefix = today.strftime("%Y-%m")
    week_total = 0
    week_count = 0
    month_total = 0
    month_count = 0
    for s in sessions:
        try:
            d = date.fromisoformat(s.get("date", ""))
            dur = int(s.get("duration", 0))
        except (ValueError, TypeError):
            continue
        if week_start <= d <= week_end:
            week_total += dur
            week_count += 1
        if d.strftime("%Y-%m") == month_prefix:
            month_total += dur
            month_count += 1

    # Last 7 days
    week_bars = []
    max_day = 1  # avoid div-by-zero
    for i in range(7):
        d = today - timedelta(days=6 - i)
        d_str = d.isoformat()
        d_total = sum(int(s.get("duration", 0)) for s in sessions if s.get("date") == d_str)
        max_day = max(max_day, d_total)
        week_bars.append({"date": d_str, "label": d.strftime("%a"), "total": d_total})

    # Last 6 months
    month_bars = []
    max_month = 1
    for i in range(5, -1, -1):
        y, m = today.year, today.month - i
        while m <= 0:
            m += 12
            y -= 1
        mk = f"{y}-{m:02d}"
        m_total = sum(int(s.get("duration", 0)) for s in sessions if s.get("date", "")[:7] == mk)
        max_month = max(max_month, m_total)
        month_bars.append({"key": mk, "label": date(y, m, 1).strftime("%b"), "total": m_total})

    # Mode totals
    mode_totals = {}
    for s in sessions:
        m = s.get("mode", "?")
        mode_totals[m] = mode_totals.get(m, 0) + int(s.get("duration", 0))
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

    # Build month bars (last 6 months)
    month_html = ""
    for b in month_bars:
        h = int((b["total"] / max_month) * 140) if max_month else 0
        is_current = b["key"] == month_prefix
        month_html += f"""
        <div class="week-day{' today' if is_current else ''}">
            <div class="week-bar-wrap"><div class="week-bar" style="height:{h}px"></div></div>
            <div class="week-label">{b['label']}</div>
            <div class="week-time">{fmt(b['total']) if b['total'] else ''}</div>
        </div>"""

    # Recent sessions list (safe sort — date + end_time)
    recent = sorted(
        sessions,
        key=lambda s: (s.get("date", ""), s.get("end_time", "")),
        reverse=True,
    )[:20]
    recent_rows = ""
    for s in recent:
        dur = int(s.get("duration", 0))
        recent_rows += f"""
        <div class="recent-row">
            <span class="recent-date">{s.get('date', '?')}</span>
            <span class="recent-mode">{s.get('mode', '?')}</span>
            <span class="recent-time">{s.get('start_time', '?')} → {s.get('end_time', '?')}</span>
            <span class="recent-dur">{s.get('duration_formatted', fmt(dur))}</span>
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
.stats-grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:32px}}
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
@media(max-width:600px){{.stats-grid{{grid-template-columns:1fr 1fr}}}}
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
            <div class="label">This Week</div>
            <div class="value">{fmt(week_total)}</div>
            <div class="sub">{week_count} session{'s' if week_count != 1 else ''}</div>
        </div>
        <div class="stat-card">
            <div class="label">This Month</div>
            <div class="value">{fmt(month_total)}</div>
            <div class="sub">{month_count} session{'s' if month_count != 1 else ''}</div>
        </div>
        <div class="stat-card">
            <div class="label">All Time</div>
            <div class="value">{fmt(grand_total)}</div>
            <div class="sub">{len(sessions)} sessions</div>
        </div>
    </div>

    <div class="card">
        <h2>📅 Last 7 Days</h2>
        <div class="week-chart">
            {week_html}
        </div>
    </div>

    <div class="card">
        <h2>🗓 Last 6 Months</h2>
        <div class="week-chart">
            {month_html}
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
            end_time = datetime.now()
            if self.current_mode == "0 - ∞":
                duration = self.elapsed_infinite
            else:
                duration = self.mode_total_seconds - self.remaining
            
            if duration >= 5:
                save_session({
                    "date": date.today().isoformat(),
                    "mode": self.current_mode,
                    "start_time": self.session_start_time.strftime("%H:%M:%S"),
                    "end_time": end_time.strftime("%H:%M:%S"),
                    "duration": duration,
                    "duration_formatted": fmt(duration),
                })
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
