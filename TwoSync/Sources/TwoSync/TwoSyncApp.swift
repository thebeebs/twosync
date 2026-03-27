import SwiftUI
import ServiceManagement

@main
struct TwoSyncApp: App {
    @StateObject private var store = JobStore()
    @StateObject private var loginItem = LoginItemManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(loginItem)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// ─── Login Item Manager ───────────────────────────────────────────────────────

class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        if #available(macOS 13.0, *) {
            isEnabled = SMAppService.mainApp.status == .enabled
        } else {
            // Fallback: check LaunchAgent plist
            isEnabled = FileManager.default.fileExists(atPath: loginItemPlistPath)
        }
    }

    func toggle() {
        if #available(macOS 13.0, *) {
            do {
                if isEnabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                isEnabled.toggle()
            } catch {
                print("Login item error: \(error)")
            }
        } else {
            // Fallback for macOS 12 — write a LaunchAgent
            if isEnabled {
                try? FileManager.default.removeItem(atPath: loginItemPlistPath)
            } else {
                writeLoginItemPlist()
            }
            isEnabled.toggle()
        }
    }

    // ── macOS 12 fallback ─────────────────────────────────────────────────────

    private var loginItemPlistPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/com.user.TwoSync.login.plist"
    }

    private func writeLoginItemPlist() {
        guard let appPath = Bundle.main.bundlePath as String? else { return }
        let label = "com.user.TwoSync.login"
        let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>\(label)</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/open</string><string>-a</string><string>\(appPath)</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
"""
        let dir = (loginItemPlistPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? plist.write(toFile: loginItemPlistPath, atomically: true, encoding: .utf8)
    }
}
