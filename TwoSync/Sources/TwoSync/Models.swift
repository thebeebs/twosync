import Foundation
import Combine

// ─── Sync Job ────────────────────────────────────────────────────────────────

struct SyncJob: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var folderA: String
    var folderB: String
    var schedule: Schedule
    var enabled: Bool = true
    var lastRun: Date?
    var lastResult: String?
    var lastStatus: JobStatus = .idle

    enum Schedule: String, Codable, CaseIterable {
        case manual     = "Manual only"
        case everyHour  = "Every hour"
        case every2h    = "Every 2 hours"
        case every4h    = "Every 4 hours"
        case every6h    = "Every 6 hours"
        case daily      = "Daily"

        var seconds: Int? {
            switch self {
            case .manual:    return nil
            case .everyHour: return 3600
            case .every2h:   return 7200
            case .every4h:   return 14400
            case .every6h:   return 21600
            case .daily:     return 86400
            }
        }

        var launchAgentInterval: Int? { seconds }
    }

    enum JobStatus: String, Codable {
        case idle, running, success, failed
    }
}

// ─── Job Store ───────────────────────────────────────────────────────────────

class JobStore: ObservableObject {
    @Published var jobs: [SyncJob] = []
    @Published var selectedJobID: UUID?
    @Published var logLines: [LogLine] = []

    private let saveURL: URL
    private let launchAgentDir: URL

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("TwoSync")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("jobs.json")

        launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")

        load()
    }

    // ── Persistence ──────────────────────────────────────────────────────────

    func load() {
        guard let data = try? Data(contentsOf: saveURL),
              let decoded = try? JSONDecoder().decode([SyncJob].self, from: data)
        else { return }
        jobs = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: saveURL)
    }

    // ── CRUD ─────────────────────────────────────────────────────────────────

    func addJob(_ job: SyncJob) {
        jobs.append(job)
        save()
        if job.enabled, job.schedule != .manual {
            installLaunchAgent(job)
        }
    }

    func updateJob(_ job: SyncJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx] = job
        save()
        uninstallLaunchAgent(job)
        if job.enabled, job.schedule != .manual {
            installLaunchAgent(job)
        }
    }

    func deleteJob(_ job: SyncJob) {
        uninstallLaunchAgent(job)
        jobs.removeAll { $0.id == job.id }
        if selectedJobID == job.id { selectedJobID = nil }
        save()
    }

    func toggleEnabled(_ job: SyncJob) {
        var j = job
        j.enabled.toggle()
        updateJob(j)
    }

    // ── Run ──────────────────────────────────────────────────────────────────

    func runJob(_ job: SyncJob) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[idx].lastStatus = .running
        appendLog("▶ Starting: \(job.name)", error: false)

        let scriptPath = scriptURL().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath, job.folderA, job.folderB, "--verbose"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    for line in str.components(separatedBy: "\n") where !line.isEmpty {
                        let isErr = line.contains("ERROR") || line.contains("CONFLICT") || line.contains("failed")
                        self?.appendLog(line, error: isErr)
                    }
                }
            }
        }

        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                let ok = p.terminationStatus == 0
                self.jobs[idx].lastStatus = ok ? .success : .failed
                self.jobs[idx].lastRun = Date()
                self.jobs[idx].lastResult = ok ? "Completed successfully" : "Exited with code \(p.terminationStatus)"
                self.appendLog(ok ? "✓ Done" : "✗ Failed (code \(p.terminationStatus))", error: !ok)
                self.save()
            }
        }

        try? process.run()
    }

    // ── LaunchAgent ──────────────────────────────────────────────────────────

    private func launchAgentLabel(_ job: SyncJob) -> String {
        "com.user.twosync.\(job.id.uuidString.lowercased())"
    }

    private func launchAgentPath(_ job: SyncJob) -> URL {
        launchAgentDir.appendingPathComponent("\(launchAgentLabel(job)).plist")
    }

    func installLaunchAgent(_ job: SyncJob) {
        guard let interval = job.schedule.launchAgentInterval else { return }
        let label = launchAgentLabel(job)
        let plistPath = launchAgentPath(job)
        let scriptPath = scriptURL().path

        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>\(label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>\(scriptPath)</string>
        <string>\(job.folderA)</string>
        <string>\(job.folderB)</string>
    </array>
    <key>StartInterval</key><integer>\(interval)</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>\(logPath())</string>
    <key>StandardErrorPath</key><string>\(logPath())</string>
</dict>
</plist>
"""
        try? FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
        try? plist.write(to: plistPath, atomically: true, encoding: .utf8)

        // Unload first, then load
        shell("launchctl unload '\(plistPath.path)' 2>/dev/null; launchctl load '\(plistPath.path)'")
        appendLog("⏰ Scheduled: \(job.schedule.rawValue) (\(job.name))", error: false)
    }

    func uninstallLaunchAgent(_ job: SyncJob) {
        let plistPath = launchAgentPath(job)
        if FileManager.default.fileExists(atPath: plistPath.path) {
            shell("launchctl unload '\(plistPath.path)' 2>/dev/null")
            try? FileManager.default.removeItem(at: plistPath)
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private func scriptURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("TwoSync/twosync.py")
    }

    private func logPath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("TwoSync/twosync.log").path
    }

    @discardableResult
    private func shell(_ cmd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func appendLog(_ text: String, error: Bool) {
        let line = LogLine(text: text, isError: error)
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    func clearLog() { logLines.removeAll() }

    var selectedJob: SyncJob? {
        jobs.first { $0.id == selectedJobID }
    }
}
