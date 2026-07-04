import SwiftUI
import Foundation

// MARK: - Model

struct PatchState {
    var realVersion: String = ""
    var reportedVersion: String = ""
    var reportedBuild: String = ""
    var isPatched: Bool = false
    var log: [LogEntry] = []
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
    let kind: Kind
    enum Kind { case info, success, error }
}

let knownVersions: [(label: String, version: String, build: String)] = [
    ("macOS 12.0  Monterey",  "12.0",   "21A559"),
    ("macOS 12.3  Monterey",  "12.3",   "21E230"),
    ("macOS 12.6  Monterey",  "12.6",   "21G115"),
    ("macOS 12.6.9 Monterey", "12.6.9", "21G931"),
    ("macOS 12.7.6 Monterey", "12.7.6", "21H1320"),
    ("macOS 13.0  Ventura",   "13.0",   "22A380"),
    ("macOS 13.5  Ventura",   "13.5",   "22G74"),
    ("macOS 13.6.9 Ventura",  "13.6.9", "22G931"),
    ("macOS 13.7.6 Ventura",  "13.7.6", "22H625"),
    ("macOS 14.0  Sonoma",    "14.0",   "23A344"),
    ("macOS 14.7.6 Sonoma",   "14.7.6", "23H626"),
]

// MARK: - ViewModel

@MainActor
class PatchViewModel: ObservableObject {
    @Published var state = PatchState()
    @Published var selectedIndex: Int = 0
    @Published var isBusy = false
    @Published var errorMessage: String? = nil

    private let patchScript: String = {
        // Resolve patch.sh next to the .app, or bundled inside it
        let appDir = Bundle.main.bundlePath
        let candidates = [
            (appDir as NSString).deletingLastPathComponent + "/patch.sh",
            Bundle.main.path(forResource: "patch", ofType: "sh") ?? ""
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/local/bin/macpatch-patch.sh"
    }()

    init() { refresh() }

    func refresh() {
        state.realVersion = readPlistKey("ProductVersion",
            from: "/System/Library/CoreServices/SystemVersion.plist.bigsur-backup")
            ?? swVers("productVersion")
        state.reportedVersion = swVers("productVersion")
        state.reportedBuild   = swVers("buildVersion")
        state.isPatched       = FileManager.default.fileExists(
            atPath: "/var/db/.macpatch-bigsur-active")
    }

    func apply() {
        let v = knownVersions[selectedIndex]
        run(args: ["apply", v.version, v.build],
            successMsg: "Patched → \(v.version) (\(v.build))")
    }

    func restore() {
        run(args: ["restore"], successMsg: "Restored to original Big Sur version")
    }

    private func run(args: [String], successMsg: String) {
        isBusy = true
        errorMessage = nil
        let script = patchScript
        let argStr = args.map { "'\($0)'" }.joined(separator: " ")
        // Use osascript to request admin password natively
        let shellCmd = "'\(script)' \(argStr)"
        let appleScript = """
            do shell script "\(shellCmd)" with administrator privileges
        """
        DispatchQueue.global().async {
            var error: NSDictionary?
            let result = NSAppleScript(source: appleScript)!
                .executeAndReturnError(&error)
            DispatchQueue.main.async {
                self.isBusy = false
                if let err = error {
                    let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error"
                    self.append(msg, kind: .error)
                    self.errorMessage = msg
                } else {
                    self.append(successMsg, kind: .success)
                    if let out = result.stringValue, !out.isEmpty {
                        self.append(out, kind: .info)
                    }
                    self.refresh()
                }
            }
        }
    }

    private func append(_ message: String, kind: LogEntry.Kind) {
        state.log.insert(LogEntry(date: Date(), message: message, kind: kind), at: 0)
    }

    private func swVers(_ flag: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
        p.arguments = ["-\(flag)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    private func readPlistKey(_ key: String, from path: String) -> String? {
        guard let dict = NSDictionary(contentsOfFile: path) else { return nil }
        return dict[key] as? String
    }
}

// MARK: - Views

struct StatusBadge: View {
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(active ? "Patch Active" : "Not Patched")
                .font(.subheadline.weight(.medium))
                .foregroundColor(active ? .green : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

struct VersionRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
    }
}

struct LogRow: View {
    let entry: LogEntry
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    var color: Color {
        switch entry.kind {
        case .success: return .green
        case .error:   return .red
        case .info:    return .primary
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.fmt.string(from: entry.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = PatchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacPatch Dashboard")
                        .font(.title2.bold())
                    Text("Big Sur compatibility patcher")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                StatusBadge(active: vm.state.isPatched)
            }
            .padding()
            .background(Color(.windowBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Version info ─────────────────────────────────────────
                    GroupBox("System Version") {
                        VStack(alignment: .leading, spacing: 8) {
                            VersionRow(label: "Real (Big Sur):",
                                       value: vm.state.realVersion.isEmpty
                                              ? "—" : vm.state.realVersion)
                            VersionRow(label: "Reported to apps:",
                                       value: "\(vm.state.reportedVersion)  (\(vm.state.reportedBuild))")
                        }
                        .padding(.top, 4)
                    }

                    // ── Controls ─────────────────────────────────────────────
                    GroupBox("Apply Patch") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Target version", selection: $vm.selectedIndex) {
                                ForEach(knownVersions.indices, id: \.self) { i in
                                    Text(knownVersions[i].label).tag(i)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack(spacing: 12) {
                                Button {
                                    vm.apply()
                                } label: {
                                    Label("Apply Patch", systemImage: "arrow.up.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(vm.isBusy)

                                Button(role: .destructive) {
                                    vm.restore()
                                } label: {
                                    Label("Restore Original", systemImage: "arrow.uturn.backward.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(vm.isBusy || !vm.state.isPatched)
                            }

                            if vm.isBusy {
                                HStack {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Running (enter your password when prompted)…")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if let err = vm.errorMessage {
                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.top, 4)
                    }

                    // ── Change log ───────────────────────────────────────────
                    GroupBox("Change Log") {
                        if vm.state.log.isEmpty {
                            Text("No actions yet this session.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(vm.state.log) { entry in
                                    LogRow(entry: entry)
                                    if entry.id != vm.state.log.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                }
                .padding()
            }

            // ── Footer ───────────────────────────────────────────────────────
            Divider()
            HStack {
                Button("Refresh Status") { vm.refresh() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Spacer()
                Text("Restore before running macOS updates")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 540)
    }
}

// MARK: - App entry point

@main
struct MacPatchDashboardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
