import AppKit
import Foundation
import Darwin

/// Minimal HTTP server on 127.0.0.1:8765. Loads fresh data per request
/// (recent + archive) so totals never go stale. No dependencies.
final class DashboardServer {
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.serve() }
    }

    func open() {
        start()
        // Give the listener a moment on cold start, then open browser.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.25)
            let url = URL(string: "http://localhost:\(Store.dashboardPort)")!
            NSWorkspace.shared.open(url)
        }
    }

    func shutdown() {
        lock.lock()
        running = false
        let fd = listenFD
        lock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, Int32(SHUT_RDWR))
            Darwin.close(fd)
        }
    }

    // MARK: - Socket loop

    private func serve() {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Store.dashboardPort).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        #if !arch(x86_64)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            lock.lock(); running = false; lock.unlock()
            return
        }
        lock.lock(); listenFD = fd; lock.unlock()

        while true {
            lock.lock()
            let alive = running
            lock.unlock()
            if !alive { break }
            var clientAddr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            if cfd < 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            handle(client: cfd)
        }
        Darwin.close(fd)
        lock.lock(); listenFD = -1; lock.unlock()
    }

    private func handle(client: Int32) {
        defer { Darwin.close(client) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(client, &buf, buf.count - 1, 0)
        guard n > 0 else { return }
        buf[Int(n)] = 0
        let request = String(bytes: buf.prefix(Int(n)), encoding: .utf8) ?? ""
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : "/"

        if path == "/" || path == "/index.html" {
            let html = Dashboard.render(sessions: Store.loadAllSessions())
            sendResponse(client: client, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        } else if path == "/api/sessions" {
            let sessions = Store.loadAllSessions()
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let body = (try? enc.encode(sessions)) ?? Data("[]".utf8)
            sendResponse(client: client, status: "200 OK", contentType: "application/json", body: body)
        } else {
            sendResponse(client: client, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func sendResponse(client: Int32, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { ptr in
            var sent = 0
            while sent < out.count {
                let r = Darwin.send(client, ptr.baseAddress!.advanced(by: sent), out.count - sent, 0)
                if r <= 0 { break }
                sent += r
            }
        }
    }
}

// MARK: - HTML rendering (ported 1:1 from chrono.py)

enum Dashboard {
    static func render(sessions: [Session]) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let mf = DateFormatter()
        mf.dateFormat = "yyyy-MM"
        mf.locale = Locale(identifier: "en_US_POSIX")
        let todayStr = df.string(from: Date())

        func dateOf(_ s: Session) -> Date? { df.date(from: s.date) }

        let todaySessions = sessions.filter { $0.date == todayStr }
        let todayTotal = todaySessions.reduce(0) { $0 + $1.duration }

        // This week Mon-Sun
        let weekday = cal.component(.weekday, from: Date()) // 1=Sun
        let daysFromMonday = (weekday + 6) % 7
        let weekStart = cal.date(byAdding: .day, value: -daysFromMonday, to: today)!
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart)!
        let monthPrefix = mf.string(from: Date())

        var weekTotal = 0, weekCount = 0, monthTotal = 0, monthCount = 0
        for s in sessions {
            guard let d = dateOf(s) else { continue }
            let day = cal.startOfDay(for: d)
            if day >= weekStart && day <= weekEnd { weekTotal += s.duration; weekCount += 1 }
            if s.date.hasPrefix(monthPrefix) { monthTotal += s.duration; monthCount += 1 }
        }

        // Daily totals (all-time) — drives the GitHub-style heatmap.
        var dailyTotals: [String: Int] = [:]
        var dailyCounts: [String: Int] = [:]
        for s in sessions {
            guard df.date(from: s.date) != nil else { continue }
            dailyTotals[s.date, default: 0] += s.duration
            dailyCounts[s.date, default: 0] += 1
        }
        // Global max keeps green intensity comparable across years.
        let globalMax = dailyTotals.values.max() ?? 0
        func heatLevel(_ total: Int) -> Int {
            guard total > 0, globalMax > 0 else { return 0 }
            let q = Double(total) / Double(globalMax)
            if q <= 0.25 { return 1 }
            if q <= 0.5 { return 2 }
            if q <= 0.75 { return 3 }
            return 4
        }
        let tipFmt = DateFormatter()
        tipFmt.dateFormat = "MMM d, yyyy"
        tipFmt.locale = Locale(identifier: "en_US_POSIX")
        let monFmt = DateFormatter()
        monFmt.dateFormat = "MMM"
        monFmt.locale = Locale(identifier: "en_US_POSIX")

        let currentYear = cal.component(.year, from: Date())
        let minYear = dailyTotals.keys.compactMap { Int($0.prefix(4)) }.min() ?? currentYear
        let years = Array(minYear...currentYear)

        // One GitHub-style table per year: continuous week-columns
        // (Sunday-before-Jan-1 through Saturday-after-Dec-31), rows Sun–Sat,
        // month labels above the first column in which each month appears.
        // Boundary columns naturally contain a few adjacent-month days,
        // exactly like GitHub.
        func yearTable(_ year: Int) -> (html: String, summary: String) {
            var dc = DateComponents()
            dc.year = year; dc.month = 1; dc.day = 1
            guard let jan1 = cal.date(from: dc) else { return ("", "") }
            dc.month = 12; dc.day = 31
            guard let dec31 = cal.date(from: dc) else { return ("", "") }
            let back = cal.component(.weekday, from: jan1) - 1   // Sun=1
            let fwd = 7 - cal.component(.weekday, from: dec31)
            let gridStart = cal.date(byAdding: .day, value: -back, to: jan1)!
            let gridEnd = cal.date(byAdding: .day, value: fwd, to: dec31)!
            let numWeeks = cal.dateComponents([.day], from: gridStart, to: gridEnd).day! / 7 + 1

            func cellHTML(week w: Int, row r: Int) -> String {
                let d = cal.date(byAdding: .day, value: w * 7 + r, to: gridStart)!
                guard cal.component(.year, from: d) == year else {
                    return "<span class=\"cell out\"></span>"
                }
                let key = df.string(from: d)
                let t = dailyTotals[key] ?? 0
                let lv = heatLevel(t)
                let tip: String
                if t > 0 {
                    let c = dailyCounts[key] ?? 0
                    tip = "\(Store.fmt(t)) across \(c) session\(c == 1 ? "" : "s") on \(tipFmt.string(from: d))"
                } else {
                    tip = "No focus time on \(tipFmt.string(from: d))"
                }
                return lv > 0
                    ? "<span class=\"cell lv\(lv)\" data-tip=\"\(tip)\"></span>"
                    : "<span class=\"cell\" data-tip=\"\(tip)\"></span>"
            }

            // Month labels: group consecutive columns by each column's first
            // in-year day — exactly 12 labels, no stray previous-December.
            // Fluid grid (gutter + one fraction per week) so the calendar
            // always fills the card edge-to-edge with no dead space.
            let cols = "30px repeat(\(numWeeks),1fr)"
            var head = "<span></span>"
            var curMon = ""
            var span = 0
            for w in 0..<numWeeks {
                var first = cal.date(byAdding: .day, value: w * 7, to: gridStart)!
                for r in 0..<7 {
                    let d = cal.date(byAdding: .day, value: w * 7 + r, to: gridStart)!
                    if cal.component(.year, from: d) == year { first = d; break }
                }
                let m = monFmt.string(from: first)
                if m == curMon {
                    span += 1
                } else {
                    if span > 0 { head += "<span class=\"month\" style=\"grid-column:span \(span)\">\(curMon)</span>" }
                    curMon = m
                    span = 1
                }
            }
            if span > 0 { head += "<span class=\"month\" style=\"grid-column:span \(span)\">\(curMon)</span>" }

            let dayNames = ["", "Mon", "", "Wed", "", "Fri", ""]
            var grid = ""
            for r in 0..<7 {
                grid += "<span class=\"day\">\(dayNames[r])</span>"
                for w in 0..<numWeeks { grid += cellHTML(week: w, row: r) }
            }

            let prefix = "\(year)-"
            let yTotal = dailyTotals.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
            let yCount = dailyCounts.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +)
            let summary = yCount > 0
                ? "\(Store.fmt(yTotal)) across \(yCount) session\(yCount == 1 ? "" : "s") in \(year)"
                : "No sessions in \(year)"
            return ("<div class=\"cal\"><div class=\"cal-head\" style=\"grid-template-columns:\(cols)\">\(head)</div><div class=\"cal-grid\" style=\"grid-template-columns:\(cols)\">\(grid)</div></div>", summary)
        }

        var yearDivs = ""
        for y in years {
            let (table, summary) = yearTable(y)
            yearDivs += "<div id=\"y-\(y)\" class=\"year-table\" data-summary=\"\(summary)\" style=\"display:none\">\(table)</div>\n"
        }
        let yearsJS = "[" + years.map(String.init).joined(separator: ",") + "]"
        var yearOptions = ""
        for y in years.reversed() {
            yearOptions += y == years.last
                ? "<option value=\"\(y)\" selected>\(y)</option>"
                : "<option value=\"\(y)\">\(y)</option>"
        }

        var modeTotals: [String: Int] = [:]
        for s in sessions { modeTotals[s.mode, default: 0] += s.duration }
        let grandTotal = modeTotals.values.reduce(0, +)

        let modeColors = ["25 min 🍅": "#ff6b6b", "50 min 🍅🍅": "#ffa94d", "0 - ∞": "#74c0fc"]
        var modeRows = ""
        for (m, total) in modeTotals.sorted(by: { $0.value > $1.value }) {
            let pct = grandTotal > 0 ? Double(total) / Double(grandTotal) * 100 : 0
            let color = modeColors[m] ?? "#868e96"
            modeRows += """
            \n        <div class="mode-row">\n            <span class="mode-dot" style="background:\(color)"></span>\n            <span class="mode-name">\(m)</span>\n            <span class="mode-bar-wrap"><span class="mode-bar" style="width:\(pct)%;background:\(color)"></span></span>\n            <span class="mode-time">\(Store.fmt(total))</span>\n        </div>
            """
        }

        let recent = sessions.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.end_time > $1.end_time
        }.prefix(20)
        var recentRows = ""
        for s in recent {
            recentRows += """
            \n        <div class="recent-row">\n            <span class="recent-date">\(s.date)</span>\n            <span class="recent-mode">\(s.mode)</span>\n            <span class="recent-time">\(s.start_time) → \(s.end_time)</span>\n            <span class="recent-dur">\(s.duration_formatted.isEmpty ? Store.fmt(s.duration) : s.duration_formatted)</span>\n        </div>
            """
        }

        // Same markup/CSS as chrono.py (dark theme).
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Chrono Dashboard</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#e6edf3;min-height:100vh;padding:40px}
        .container{max-width:900px;margin:0 auto}
        h1{font-size:28px;font-weight:700;margin-bottom:8px;display:flex;align-items:center;gap:10px}
        .subtitle{color:#8b949e;font-size:14px;margin-bottom:32px}
        .stats-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:32px}
        .stat-card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:20px;text-align:center}
        .stat-card .label{color:#8b949e;font-size:12px;text-transform:uppercase;letter-spacing:.5px;margin-bottom:6px}
        .stat-card .value{font-size:32px;font-weight:700;color:#f0f6fc}
        .stat-card .sub{color:#8b949e;font-size:12px;margin-top:4px}
        .card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:24px;margin-bottom:20px}
        .card h2{font-size:16px;font-weight:600;margin-bottom:16px;color:#f0f6fc}
        .cal-nav{display:flex;align-items:center;gap:10px;margin-bottom:12px}
        .cal-nav select{background:#21262d;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:4px 8px;font-size:14px;font-weight:600;cursor:pointer}
        .year-total{color:#8b949e;font-size:13px}
        .cal-wrap{padding-bottom:4px}
        .cal-head,.cal-grid{display:grid;gap:3px;align-items:center}
        .cal-head{margin-bottom:4px}
        .cal-head .month{font-size:10px;color:#8b949e;white-space:nowrap;overflow:hidden}
        .cal-grid .day{font-size:9px;color:#8b949e;white-space:nowrap}
        .cell{aspect-ratio:1/1;width:100%;border-radius:2px;background:#161b22;border:1px solid #21262d}
        .legend .cell{width:11px;aspect-ratio:auto;height:11px}
        .cell.out{background:transparent;border-color:transparent}
        .tip{position:fixed;display:none;background:#30363d;border:1px solid #484f58;color:#f0f6fc;font-size:12px;padding:6px 10px;border-radius:6px;pointer-events:none;z-index:10;white-space:nowrap}
        .cell.lv1{background:#0e4429;border-color:#0e4429}
        .cell.lv2{background:#006d32;border-color:#006d32}
        .cell.lv3{background:#26a641;border-color:#26a641}
        .cell.lv4{background:#39d353;border-color:#39d353}
        .legend{display:flex;align-items:center;gap:4px;justify-content:flex-end;margin-top:10px;font-size:11px;color:#8b949e}
        .legend .cell{display:inline-block}
        .mode-row{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid #21262d}
        .mode-row:last-child{border-bottom:none}
        .mode-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
        .mode-name{width:140px;font-size:14px}
        .mode-bar-wrap{flex:1;height:8px;background:#21262d;border-radius:4px;overflow:hidden}
        .mode-bar{display:block;height:100%;border-radius:4px;transition:width .3s}
        .mode-time{width:70px;text-align:right;font-size:14px;font-weight:600;color:#f0f6fc}
        .recent-row{display:flex;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid #21262d;font-size:13px}
        .recent-row:last-child{border-bottom:none}
        .recent-date{width:90px;color:#8b949e;flex-shrink:0}
        .recent-mode{width:120px;flex-shrink:0}
        .recent-time{flex:1;color:#8b949e}
        .recent-dur{width:70px;text-align:right;font-weight:600;color:#f0f6fc}
        @media(max-width:600px){.stats-grid{grid-template-columns:1fr 1fr}}
        </style>
        </head>
        <body>
        <div class="container">
            <h1>🍅 Chrono Dashboard</h1>
            <p class="subtitle">Your focus data, locally stored</p>

            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Today</div>
                    <div class="value">\(Store.fmt(todayTotal))</div>
                    <div class="sub">\(todaySessions.count) session\(todaySessions.count == 1 ? "" : "s")</div>
                </div>
                <div class="stat-card">
                    <div class="label">This Week</div>
                    <div class="value">\(Store.fmt(weekTotal))</div>
                    <div class="sub">\(weekCount) session\(weekCount == 1 ? "" : "s")</div>
                </div>
                <div class="stat-card">
                    <div class="label">This Month</div>
                    <div class="value">\(Store.fmt(monthTotal))</div>
                    <div class="sub">\(monthCount) session\(monthCount == 1 ? "" : "s")</div>
                </div>
                <div class="stat-card">
                    <div class="label">All Time</div>
                    <div class="value">\(Store.fmt(grandTotal))</div>
                    <div class="sub">\(sessions.count) sessions</div>
                </div>
            </div>

            <div class="card">
                <h2>🔥 Activity</h2>
                <div class="cal-nav">
                    <select id="yearSel" onchange="pick(this.value)">
                        \(yearOptions)
                    </select>
                    <span class="year-total" id="yearTotal"></span>
                </div>
                <div class="cal-wrap">
                    \(yearDivs)
                </div>
                <div class="legend">Less <span class="cell"></span><span class="cell lv1"></span><span class="cell lv2"></span><span class="cell lv3"></span><span class="cell lv4"></span> More</div>
            </div>
        <div id="tip" class="tip"></div>

            <div class="card">
                <h2>🍅 By Mode</h2>
                \(modeRows.isEmpty ? "<p style=\"color:#8b949e;font-size:14px\">No sessions yet — start your first focus session!</p>" : modeRows)
            </div>

            <div class="card">
                <h2>🕐 Recent Sessions</h2>
                \(recentRows.isEmpty ? "<p style=\"color:#8b949e;font-size:14px\">No sessions yet</p>" : recentRows)
            </div>
        </div>
        <script>
        const years=\(yearsJS);
        function show(y){y=parseInt(y,10);
        const tables=document.querySelectorAll('.year-table');
        for(let k=0;k<tables.length;k++){tables[k].style.display=tables[k].id==='y-'+y?'block':'none';}
        document.getElementById('yearSel').value=y;
        document.getElementById('yearTotal').textContent=document.getElementById('y-'+y).dataset.summary;}
        function pick(v){show(v);}
        const tip=document.getElementById('tip');
        document.querySelectorAll('.cal-grid .cell[data-tip]').forEach(function(el){
        el.addEventListener('mouseenter',function(){tip.textContent=el.dataset.tip;tip.style.display='block';});
        el.addEventListener('mousemove',function(e){tip.style.left=(e.clientX+12)+'px';tip.style.top=(e.clientY+12)+'px';});
        el.addEventListener('mouseleave',function(){tip.style.display='none';});});
        show(years[years.length-1]);
        </script>
        </body>
        </html>
        """
    }
}
