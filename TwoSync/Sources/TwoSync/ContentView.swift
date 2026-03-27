import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: JobStore

    var body: some View {
        NavigationSplitView {
            JobListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            if let job = store.selectedJob {
                JobDetailView(job: job)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { store.selectedJobID = nil }) {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle sidebar")
            }
        }
    }
}

// ─── Job List (sidebar) ───────────────────────────────────────────────────────

struct JobListView: View {
    @EnvironmentObject var store: JobStore
    @EnvironmentObject var loginItem: LoginItemManager
    @State private var showingAdd = false
    @State private var showingPrefs = false

    var body: some View {
        VStack(spacing: 0) {
            List(store.jobs, selection: $store.selectedJobID) { job in
                JobRowView(job: job)
                    .tag(job.id)
                    .contextMenu {
                        Button("Run Now") { store.runJob(job) }
                        Button(job.enabled ? "Disable" : "Enable") { store.toggleEnabled(job) }
                        Divider()
                        Button("Delete", role: .destructive) { store.deleteJob(job) }
                    }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom toolbar
            HStack(spacing: 0) {
                // Add job
                Button {
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add sync job")

                // Remove selected job
                Button {
                    if let job = store.selectedJob { store.deleteJob(job) }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundColor(store.selectedJob != nil ? .red : .secondary)
                .disabled(store.selectedJob == nil)
                .help("Remove selected job")

                Spacer()

                // Settings / preferences
                Button {
                    showingPrefs = true
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Preferences")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showingAdd) {
            AddJobView()
        }
        .sheet(isPresented: $showingPrefs) {
            PreferencesView()
        }
    }
}

struct JobRowView: View {
    let job: SyncJob
    @EnvironmentObject var store: JobStore

    var statusColor: Color {
        guard job.enabled else { return .secondary }
        switch job.lastStatus {
        case .idle:    return .secondary
        case .running: return .orange
        case .success: return .green
        case .failed:  return .red
        }
    }

    var statusIcon: String {
        switch job.lastStatus {
        case .idle:    return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed:  return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(job.enabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(job.schedule.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// ─── Job Detail ───────────────────────────────────────────────────────────────

struct JobDetailView: View {
    let job: SyncJob
    @EnvironmentObject var store: JobStore
    @State private var showingEdit = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.title2.bold())
                    HStack(spacing: 8) {
                        if let last = job.lastRun {
                            Text("Last run: \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never run")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if job.watchContinuously && store.isWatching(job) {
                            Label("Watching", systemImage: "eye.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                Spacer()

                Button {
                    showingEdit = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    store.runJob(job)
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(job.lastStatus == .running)
            }
            .padding(20)

            Divider()

            // Folder paths
            VStack(spacing: 0) {
                FolderRow(label: "Folder A", path: job.folderA)
                Divider().padding(.leading, 16)
                FolderRow(label: "Folder B", path: job.folderB)
                Divider().padding(.leading, 16)

                HStack {
                    Label("Schedule", systemImage: "clock")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(job.schedule.rawValue)
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { job.enabled },
                        set: { _ in store.toggleEnabled(job) }
                    ))
                    .labelsHidden()
                    .help(job.enabled ? "Disable this job" : "Enable this job")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .padding(16)

            Divider()

            // Log
            LogView()
        }
        .sheet(isPresented: $showingEdit) {
            AddJobView(existing: job)
        }
    }
}

struct FolderRow: View {
    let label: String
    let path: String

    var body: some View {
        HStack {
            Label(label, systemImage: "folder.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(path)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// ─── Log View ─────────────────────────────────────────────────────────────────

struct LogView: View {
    @EnvironmentObject var store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") { store.clearLog() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.logLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(line.isError ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: store.logLines.count) { _ in
                    if let last = store.logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// ─── Add / Edit Job Sheet ─────────────────────────────────────────────────────

struct AddJobView: View {
    @EnvironmentObject var store: JobStore
    @Environment(\.dismiss) var dismiss

    var existing: SyncJob?

    @State private var name: String = ""
    @State private var folderA: String = ""
    @State private var folderB: String = ""
    @State private var schedule: SyncJob.Schedule = .everyHour
    @State private var watchContinuously: Bool = false
    @State private var enabled: Bool = true

    private var isEditing: Bool { existing != nil }
    private var isValid: Bool { !name.isEmpty && !folderA.isEmpty && !folderB.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(isEditing ? "Edit Sync Job" : "New Sync Job")
                    .font(.title3.bold())
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    TextField("Job name (e.g. Work Backup)", text: $name)
                } header: {
                    Text("Name")
                }

                Section {
                    FolderPickerRow(label: "Folder A", path: $folderA)
                    FolderPickerRow(label: "Folder B", path: $folderB)
                } header: {
                    Text("Folders to sync")
                } footer: {
                    Text("Files will be kept in sync in both directions. Deletions in either folder will be mirrored.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker("Scheduled sync", selection: $schedule) {
                        ForEach(SyncJob.Schedule.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    Toggle(isOn: $watchContinuously) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Monitor continuously")
                            Text("Sync individual files seconds after they change, in addition to the schedule above. TwoSync won't re-sync files it placed itself.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle("Enabled", isOn: $enabled)
                } header: {
                    Text("Schedule")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button(isEditing ? "Save" : "Add Job") {
                    if isEditing, var job = existing {
                        job.name = name
                        job.folderA = folderA
                        job.folderB = folderB
                        job.schedule = schedule
                        job.watchContinuously = watchContinuously
                        job.enabled = enabled
                        store.updateJob(job)
                    } else {
                        let job = SyncJob(
                            name: name,
                            folderA: folderA,
                            folderB: folderB,
                            schedule: schedule,
                            watchContinuously: watchContinuously,
                            enabled: enabled
                        )
                        store.addJob(job)
                        store.selectedJobID = job.id
                    }
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 480)
        .onAppear {
            if let job = existing {
                name = job.name
                folderA = job.folderA
                folderB = job.folderB
                schedule = job.schedule
                watchContinuously = job.watchContinuously
                enabled = job.enabled
            }
        }
    }
}

struct FolderPickerRow: View {
    let label: String
    @Binding var path: String

    var body: some View {
        HStack {
            TextField(label, text: $path)
                .font(.system(size: 12, design: .monospaced))

            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.prompt = "Select"
                if panel.runModal() == .OK, let url = panel.url {
                    path = url.path
                }
            }
            .controlSize(.small)
        }
    }
}

// ─── Preferences Sheet ───────────────────────────────────────────────────────

struct PreferencesView: View {
    @EnvironmentObject var loginItem: LoginItemManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preferences")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.return)
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { _ in loginItem.toggle() }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Launch TwoSync at login")
                                .font(.system(size: 13))
                            Text("TwoSync will open automatically when you log in to your Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("General")
                }
            }
            .formStyle(.grouped)
            .frame(height: 140)

            Spacer()
        }
        .frame(width: 400, height: 220)
        .onAppear { loginItem.refresh() }
    }
}

// ─── Empty State ──────────────────────────────────────────────────────────────

struct EmptyStateView: View {
    @EnvironmentObject var store: JobStore
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No sync job selected")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("Add a job to start syncing two folders automatically.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Sync Job…") { showingAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAdd) {
            AddJobView()
        }
    }
}
