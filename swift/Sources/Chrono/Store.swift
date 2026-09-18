import Foundation

/// Session row. Schema is byte-compatible with chrono.py so old data carries over.
struct Session: Codable {
    var date: String
    var mode: String
    var start_time: String
    var end_time: String
    var duration: Int
    var duration_formatted: String
}

enum Store {
    static let dashboardPort = 8765
    static let archiveAfterDays = 90

    static var dataDir: URL {
        if let override = ProcessInfo.processInfo.environment["CHRONO_DATA_DIR"], !override.isEmpty {
            let u = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chrono", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        migrateLegacyData(into: u)
        return u
    }

    static var sessionsFile: URL { dataDir.appendingPathComponent("sessions.json") }
    static var summariesFile: URL { dataDir.appendingPathComponent("summaries.json") }
    static var archiveDir: URL { dataDir.appendingPathComponent("archive", isDirectory: true) }

    // MARK: - Migration (one-time, never overwrites)

    static func migrateLegacyData(into dest: URL) {
        var candidates: [URL] = []
        // Running from source or old bundle layout: repo/swift/../../data is not it;
        // legacy locations are the repo `data/` dir and old dist bundles.
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("data", isDirectory: true))
        // swift/ subdir case: repo root is one level up
        candidates.append(cwd.appendingPathComponent("../data", isDirectory: true))
        let dist = cwd.appendingPathComponent("dist", isDirectory: true)
        for app in ["Chrono.app", "Kairos.app"] {
            candidates.append(dist.appendingPathComponent("\(app)/Contents/Resources/data", isDirectory: true))
        }
        // When running inside dist/Chrono.app/Contents/MacOS, walk up to dist/
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? "")
        let exeDir = exe.deletingLastPathComponent()
        // .../Chrono.app/Contents/MacOS -> .../dist
        let maybeDist = exeDir
            .deletingLastPathComponent() // MacOS -> Contents
            .deletingLastPathComponent() // Contents -> Chrono.app
            .deletingLastPathComponent() // Chrono.app -> dist
        if maybeDist.lastPathComponent == "dist" {
            for app in ["Chrono.app", "Kairos.app"] {
                candidates.append(maybeDist.appendingPathComponent("\(app)/Contents/Resources/data", isDirectory: true))
            }
        }
        for src in candidates {
            let resolved = src.standardizedFileURL
            guard fm.fileExists(atPath: resolved.path),
                  resolved.standardizedFileURL.path != dest.standardizedFileURL.path else { continue }
            for name in ["sessions.json", "summaries.json"] {
                let s = resolved.appendingPathComponent(name)
                let t = dest.appendingPathComponent(name)
                if fm.fileExists(atPath: s.path) && !fm.fileExists(atPath: t.path) {
                    try? fm.copyItem(at: s, to: t)
                }
            }
            let srcArch = resolved.appendingPathComponent("archive", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: srcArch.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.createDirectory(at: dest.appendingPathComponent("archive", isDirectory: true), withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(at: srcArch, includingPropertiesForKeys: nil)) ?? [] {
                    guard f.pathExtension == "json" else { continue }
                    let t = dest.appendingPathComponent("archive", isDirectory: true).appendingPathComponent(f.lastPathComponent)
                    if !fm.fileExists(atPath: t.path) {
                        try? fm.copyItem(at: f, to: t)
                    }
                }
            }
        }
    }

    // MARK: - Load

    static func loadSessions() -> [Session] {
        let u = sessionsFile
        guard let data = try? Data(contentsOf: u),
              let list = try? JSONDecoder().decode([Session].self, from: data) else { return [] }
        return list
    }

    static func loadAllSessions() -> [Session] {
        var all = loadSessions()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil) else { return all }
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard f.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: f),
                  let list = try? JSONDecoder().decode([Session].self, from: data) else { continue }
            all.append(contentsOf: list)
        }
        return all
    }

    // MARK: - Summaries + maintenance

    static func weekKey(for d: Date, cal: Calendar = .current) -> String {
        let c = cal
        let y = c.component(.yearForWeekOfYear, from: d)
        let w = c.component(.weekOfYear, from: d)
        return String(format: "%d-W%02d", y, w)
    }

    static func buildSummaries(_ sessions: [Session]) -> [String: [String: [String: Int]]] {
        var daily: [String: [String: Int]] = [:]
        var weekly: [String: [String: Int]] = [:]
        var monthly: [String: [String: Int]] = [:]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let mf = DateFormatter()
        mf.dateFormat = "yyyy-MM"
        mf.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        for s in sessions {
            guard let d = df.date(from: s.date) else { continue }
            let dk = s.date
            let wk = weekKey(for: d, cal: cal)
            let mk = mf.string(from: d)
            daily[dk, default: ["total": 0, "sessions": 0]]["total"]! += s.duration
            daily[dk]!["sessions"]! += 1
            weekly[wk, default: ["total": 0, "sessions": 0]]["total"]! += s.duration
            weekly[wk]!["sessions"]! += 1
            monthly[mk, default: ["total": 0, "sessions": 0]]["total"]! += s.duration
            monthly[mk]!["sessions"]! += 1
        }
        return ["daily": daily, "weekly": weekly, "monthly": monthly]
    }

    @discardableResult
    static func runMaintenance() -> [String: [String: [String: Int]]] {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        var sessions = loadSessions()
        if sessions.isEmpty {
            let summaries = buildSummaries(loadAllSessions())
            writeJSON(summaries, to: summariesFile)
            return summaries
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let mf = DateFormatter()
        mf.dateFormat = "yyyy-MM"
        mf.locale = Locale(identifier: "en_US_POSIX")
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -archiveAfterDays, to: Date()) else {
            let summaries = buildSummaries(loadAllSessions())
            writeJSON(summaries, to: summariesFile)
            return summaries
        }
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)
        var keep: [Session] = []
        var oldByMonth: [String: [Session]] = [:]
        for s in sessions {
            guard let d = df.date(from: s.date) else { keep.append(s); continue }
            if d < cutoffDay {
                oldByMonth[mf.string(from: d), default: []].append(s)
            } else {
                keep.append(s)
            }
        }
        for (month, items) in oldByMonth {
            let dest = archiveDir.appendingPathComponent("\(month).json")
            var merged = items
            if let data = try? Data(contentsOf: dest),
               let prior = try? JSONDecoder().decode([Session].self, from: data) {
                merged = prior + items
            }
            writeJSONEncodable(merged, to: dest)
        }
        if !oldByMonth.isEmpty {
            writeJSONEncodable(keep, to: sessionsFile)
            sessions = keep
        }
        let summaries = buildSummaries(loadAllSessions())
        writeJSON(summaries, to: summariesFile)
        return summaries
    }

    static func saveSession(_ s: Session) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        var sessions = loadSessions()
        sessions.append(s)
        writeJSONEncodable(sessions, to: sessionsFile)
        _ = runMaintenance()
    }

    static func makeSession(mode: String, start: Date, end: Date, duration: Int) -> Session {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        tf.locale = Locale(identifier: "en_US_POSIX")
        return Session(
            date: df.string(from: Date()),
            mode: mode,
            start_time: tf.string(from: start),
            end_time: tf.string(from: end),
            duration: duration,
            duration_formatted: fmt(duration)
        )
    }

    // MARK: - Format

    static func fmt(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    // MARK: - JSON helpers

    static func writeJSON(_ obj: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func writeJSONEncodable<T: Encodable>(_ obj: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(obj) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
