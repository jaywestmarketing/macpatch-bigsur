import SwiftUI
import Foundation

// MARK: - Data model

struct PatchableApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String
    let requiredVersion: String
    var isPatched: Bool
    var iconImage: NSImage?

    var displayVersion: String { requiredVersion }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: PatchableApp, b: PatchableApp) -> Bool { a.id == b.id }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let message: String
    let kind: Kind
    enum Kind { case info, success, error }

    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

// MARK: - App scanner

struct AppScanner {
    static let searchDirs = ["/Applications", "\(NSHomeDirectory())/Applications"]
    static let bigsurVer  = OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)

    static func scan() -> [PatchableApp] {
        var results: [PatchableApp] = []
        let fm = FileManager.default

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appPath = "\(dir)/\(item)"
                let plistPath = "\(appPath)/Contents/Info.plist"
                guard let dict = NSDictionary(contentsOfFile: plistPath) else { continue }

                let minVer = (dict["LSMinimumSystemVersion"] as? String) ?? ""
                guard !minVer.isEmpty else { continue }

                let parts = minVer.split(separator: ".").compactMap { Int($0) }
                guard parts.count >= 1, parts[0] >= 12 else { continue }

                let name     = (dict["CFBundleName"] as? String)
                           ?? (dict["CFBundleDisplayName"] as? String)
                           ?? item.replacingOccurrences(of: ".app", with: "")
                let bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
                let backup   = "\(plistPath).macpatch-backup"
                let patched  = fm.fileExists(atPath: backup)
                let icon     = NSWorkspace.shared.icon(forFile: appPath)

                results.append(PatchableApp(
                    name: name,
                    path: appPath,
                    bundleID: bundleID,
                    requiredVersion: minVer,
                    isPatched: patched,
                    iconImage: icon
                ))
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Privileged runner

struct PrivilegedRunner {
    /// Runs a shell command with admin privileges via AppleScript password prompt.
    static func run(_ cmd: String) throws -> String {
        let src = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        let result = NSAppleScript(source: src)!.executeAndReturnError(&err)
        if let e = err {
            throw RunnerError.failed((e["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error")
        }
        return result.stringValue ?? ""
    }

    enum RunnerError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let m) = self { return m }
            return nil
        }
    }
}

// MARK: - Patch operations

struct Patcher {
    static func scriptDir() -> String {
        let bundle  = Bundle.main.bundlePath
        let sibling = (bundle as NSString).deletingLastPathComponent + "/patch-app.sh"
        if FileManager.default.fileExists(atPath: sibling) { return sibling }
        return Bundle.main.path(forResource: "patch-app", ofType: "sh") ?? sibling
    }

    static func apply(app: PatchableApp) throws {
        let sh = scriptDir()
        try PrivilegedRunner.run("'\(sh)' apply '\(app.path)'")
    }

    static func restore(app: PatchableApp) throws {
        let sh = scriptDir()
        try PrivilegedRunner.run("'\(sh)' restore '\(app.path)'")
    }
}

// MARK: - ViewModel

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var apps: [PatchableApp] = []
    @Published var log: [LogEntry] = []
    @Published var isBusy = false
    @Published var busyMessage = ""
    @Published var selected = Set<UUID>()

    func scan() async {
        isBusy = true
        busyMessage = "Scanning /Applications…"
        apps = await Task.detached(priority: .userInitiated) {
            AppScanner.scan()
        }.value
        isBusy = false
        append("Found \(apps.count) app(s) requiring macOS 12 or higher.", kind: .info)
    }

    func applyAll() { operate(apps: apps.filter { !$0.isPatched }, action: .apply) }
    func restoreAll() { operate(apps: apps.filter { $0.isPatched }, action: .restore) }

    func applySelected()   { operate(apps: selectedApps().filter { !$0.isPatched }, action: .apply) }
    func restoreSelected() { operate(apps: selectedApps().filter { $0.isPatched }, action: .restore) }

    private func selectedApps() -> [PatchableApp] {
        apps.filter { selected.contains($0.id) }
    }

    private enum Action { case apply, restore }

    private func operate(apps targets: [PatchableApp], action: Action) {
        guard !targets.isEmpty else { return }
        isBusy = true
        Task {
            for app in targets {
                busyMessage = "\(action == .apply ? "Patching" : "Restoring") \(app.name)…"
                do {
                    if action == .apply { try Patcher.apply(app: app) }
                    else                { try Patcher.restore(app: app) }
                    await updatePatched(id: app.id, patched: action == .apply)
                    append("\(action == .apply ? "Patched" : "Restored"): \(app.name)", kind: .success)
                } catch {
                    append("Failed \(app.name): \(error.localizedDescription)", kind: .error)
                }
            }
            isBusy = false
            busyMessage = ""
        }
    }

    private func updatePatched(id: UUID, patched: Bool) {
        if let i = apps.firstIndex(where: { $0.id == id }) {
            apps[i].isPatched = patched
        }
    }

    private func append(_ msg: String, kind: LogEntry.Kind) {
        log.insert(LogEntry(date: Date(), message: msg, kind: kind), at: 0)
    }
}

// MARK: - Phase

enum Phase { case welcome, installing, dashboard }

@MainActor
class AppState: ObservableObject {
    @Published var phase: Phase = .welcome
    @Published var installProgress: Double = 0
    @Published var installStep = ""
    let vm = DashboardViewModel()

    func runInstall() async {
        phase = .installing

        let steps: [(String, Double, Double)] = [
            ("Verifying system requirements…", 0.0, 0.15),
            ("Locating patch tools…",          0.15, 0.30),
            ("Scanning /Applications…",        0.30, 0.70),
            ("Building app list…",             0.70, 0.90),
            ("Ready.",                         0.90, 1.00),
        ]

        for (label, from, to) in steps {
            installStep = label
            // Animate progress smoothly across the range
            let ticks = 20
            for t in 0...ticks {
                installProgress = from + (to - from) * Double(t) / Double(ticks)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            // Do actual work at the scan step
            if label.contains("Scanning") {
                await vm.scan()
            }
        }

        try? await Task.sleep(nanoseconds: 400_000_000)
        phase = .dashboard
    }
}

// MARK: - Views

// ── Welcome ──────────────────────────────────────────────────────────────────

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "shield.checkmark.fill")
                    .resizable().scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )

                Text("MacPatch Dashboard")
                    .font(.largeTitle.bold())

                Text("Run macOS 12+ apps on Big Sur without disabling System Integrity Protection.\nApp compatibility is patched directly — no system files are modified.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 400)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await appState.runInstall() }
                } label: {
                    Text("Get Started")
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Requires macOS 11 Big Sur")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── Install progress ──────────────────────────────────────────────────────────

struct InstallView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.checkmark.fill")
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .cyan],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )

            VStack(spacing: 16) {
                Text("Setting up MacPatch…")
                    .font(.title2.bold())

                ProgressView(value: appState.installProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 360)
                    .animation(.easeInOut(duration: 0.1), value: appState.installProgress)

                Text(appState.installStep)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(height: 20)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── App row ───────────────────────────────────────────────────────────────────

struct AppRow: View {
    let app: PatchableApp
    @Binding var selected: Set<UUID>

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Image(systemName: selected.contains(app.id)
                  ? "checkmark.square.fill" : "square")
                .foregroundColor(selected.contains(app.id) ? .accentColor : .secondary)
                .onTapGesture { toggle() }

            // App icon
            if let img = app.iconImage {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 32, height: 32)
                    .foregroundColor(.secondary)
            }

            // Name + path
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(.medium)
                Text(app.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Required version chip
            Text("Requires \(app.displayVersion)+")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundColor(.orange)

            // Patch status
            if app.isPatched {
                Label("Patched", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.green)
            } else {
                Label("Needs patch", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .padding(.vertical, 4)
    }

    private func toggle() {
        if selected.contains(app.id) { selected.remove(app.id) }
        else { selected.insert(app.id) }
    }
}

// ── Log row ───────────────────────────────────────────────────────────────────

struct LogRow: View {
    let entry: LogEntry
    var color: Color {
        switch entry.kind {
        case .success: return .green
        case .error:   return .red
        case .info:    return .secondary
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(LogEntry.fmt.string(from: entry.date))
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

// ── Dashboard ─────────────────────────────────────────────────────────────────

struct DashboardView: View {
    @ObservedObject var vm: DashboardViewModel

    private var patchedCount: Int { vm.apps.filter { $0.isPatched }.count }
    private var unpatchedCount: Int { vm.apps.filter { !$0.isPatched }.count }
    private var anySelected: Bool { !vm.selected.isEmpty }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 16) {
                Image(systemName: "shield.checkmark.fill")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))

                VStack(alignment: .leading, spacing: 2) {
                    Text("MacPatch Dashboard")
                        .font(.headline)
                    Text("\(patchedCount) patched · \(unpatchedCount) unpatched · \(vm.apps.count) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    Task { await vm.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(vm.isBusy)
            }
            .padding()
            .background(Color(.windowBackgroundColor).opacity(0.7))

            Divider()

            // ── App list ──────────────────────────────────────────────────
            if vm.apps.isEmpty && !vm.isBusy {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("No apps requiring macOS 12+ found.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(vm.apps, selection: $vm.selected) { app in
                    AppRow(app: app, selected: $vm.selected)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // ── Toolbar ───────────────────────────────────────────────────
            VStack(spacing: 0) {
                if vm.isBusy {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.75)
                        Text(vm.busyMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                HStack(spacing: 10) {
                    // Select all / none
                    Button(vm.selected.count == vm.apps.count ? "Deselect All" : "Select All") {
                        if vm.selected.count == vm.apps.count {
                            vm.selected.removeAll()
                        } else {
                            vm.selected = Set(vm.apps.map { $0.id })
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)

                    Spacer()

                    // Restore selected
                    Button {
                        anySelected ? vm.restoreSelected() : vm.restoreAll()
                    } label: {
                        Label(anySelected ? "Restore Selected" : "Restore All",
                              systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy || vm.apps.filter({ $0.isPatched }).isEmpty)

                    // Apply selected
                    Button {
                        anySelected ? vm.applySelected() : vm.applyAll()
                    } label: {
                        Label(anySelected ? "Patch Selected" : "Patch All",
                              systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy || vm.apps.filter({ !$0.isPatched }).isEmpty)
                }
                .padding()
            }
            .background(Color(.windowBackgroundColor).opacity(0.7))

            Divider()

            // ── Log ───────────────────────────────────────────────────────
            if !vm.log.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.log) { LogRow(entry: $0) }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .frame(height: 100)
                .background(Color(.textBackgroundColor).opacity(0.4))
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.phase {
            case .welcome:    WelcomeView()
            case .installing: InstallView()
            case .dashboard:  DashboardView(vm: appState.vm)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.phase)
        .frame(minWidth: 660, minHeight: 500)
    }
}

// MARK: - App

@main
struct MacPatchDashboardApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
