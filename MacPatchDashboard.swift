import SwiftUI
import AppKit
import Foundation

// MARK: - Model

struct PatchableApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String
    let requiredVersion: String
    var isPatched: Bool
    var iconImage: NSImage?

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

// MARK: - Scanner

struct AppScanner {
    static let searchDirs = ["/Applications", "\(NSHomeDirectory())/Applications"]

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
                let name = (dict["CFBundleName"] as? String)
                        ?? (dict["CFBundleDisplayName"] as? String)
                        ?? item.replacingOccurrences(of: ".app", with: "")
                let bundleID = (dict["CFBundleIdentifier"] as? String) ?? ""
                let backup   = "\(plistPath).macpatch-backup"
                let patched  = fm.fileExists(atPath: backup)
                let icon     = NSWorkspace.shared.icon(forFile: appPath)
                results.append(PatchableApp(
                    name: name, path: appPath, bundleID: bundleID,
                    requiredVersion: minVer, isPatched: patched, iconImage: icon))
            }
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Privileged runner

enum RunnerError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
}

func runPrivileged(_ cmd: String) throws -> String {
    let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(escaped)\" with administrator privileges"
    var err: NSDictionary?
    let result = NSAppleScript(source: src)!.executeAndReturnError(&err)
    if let e = err {
        throw RunnerError.failed((e["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error")
    }
    return result.stringValue ?? ""
}

// MARK: - Patcher

struct Patcher {
    static func scriptPath() -> String {
        let exe    = Bundle.main.executablePath ?? ""
        let macOS  = (exe as NSString).deletingLastPathComponent
        let res    = (macOS as NSString)
                        .appendingPathComponent("../Resources/patch-app.sh")
        let norm   = (res as NSString).standardizingPath
        if FileManager.default.fileExists(atPath: norm) { return norm }
        return (macOS as NSString).appendingPathComponent("patch-app.sh")
    }
    static func apply(app: PatchableApp) throws {
        _ = try runPrivileged("'\(scriptPath())' apply '\(app.path)'")
    }
    static func restore(app: PatchableApp) throws {
        _ = try runPrivileged("'\(scriptPath())' restore '\(app.path)'")
    }
}

// MARK: - Store model (plugins + hardware gate)

enum GateVerdict { case pass, block, unknown }

struct StorePlugin: Identifiable {
    let id: String
    let name: String
    let vendor: String
    let category: String
    let appPath: String
    let filePath: String        // path to the .mplugin file
    let minRamGB: Int
    let minCores: Int
    let archReq: String
    // Filled in by the gate:
    var gateVerdict: GateVerdict = .unknown
    var gateReasons: [String] = []
}

struct Store {
    /// Locate the bundled scripts/plugins directory (Resources), with dev fallback.
    static func resourcesDir() -> String {
        let exe   = Bundle.main.executablePath ?? ""
        let macOS = (exe as NSString).deletingLastPathComponent
        let res   = ((macOS as NSString).appendingPathComponent("../Resources") as NSString)
                        .standardizingPath
        if FileManager.default.fileExists(atPath: res) { return res }
        return macOS
    }

    static func probePath() -> String {
        let p = (resourcesDir() as NSString).appendingPathComponent("probe.sh")
        return p
    }

    static func loadPlugins() -> [StorePlugin] {
        let dir = (resourcesDir() as NSString).appendingPathComponent("plugins")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [StorePlugin] = []
        for f in files where f.hasSuffix(".mplugin") {
            let full = (dir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: full),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let req = (json["requirements"] as? [String: Any]) ?? [:]
            out.append(StorePlugin(
                id:       (json["id"] as? String) ?? f,
                name:     (json["name"] as? String) ?? f,
                vendor:   (json["vendor"] as? String) ?? "",
                category: (json["category"] as? String) ?? "",
                appPath:  (json["app_path"] as? String) ?? "",
                filePath: full,
                minRamGB: (req["min_ram_gb"] as? Int) ?? 0,
                minCores: (req["min_cpu_cores"] as? Int) ?? 0,
                archReq:  (req["arch"] as? String) ?? "any"
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Runs `probe.sh gate <plugin>`. exit 0 = pass, exit 2 = block.
    /// Fail-closed: any error or unexpected exit is treated as BLOCK.
    static func runGate(_ plugin: StorePlugin) -> (GateVerdict, [String]) {
        let probe = probePath()
        guard FileManager.default.isExecutableFile(atPath: probe) else {
            return (.block, ["probe.sh not found — cannot verify hardware, blocked for safety"])
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [probe, "gate", plugin.filePath]
        let out = Pipe(); let err = Pipe()
        task.standardOutput = out
        task.standardError  = err
        do { try task.run() } catch {
            return (.block, ["Could not run hardware check: \(error.localizedDescription)"])
        }
        task.waitUntilExit()
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let reasons = errStr.split(separator: "\n").map {
            String($0).replacingOccurrences(of: "BLOCK: ", with: "")
        }
        if task.terminationStatus == 0 {
            return (.pass, [])
        } else {
            // Any non-zero (including 2) = block. Fail-closed.
            return (.block, reasons.isEmpty ? ["Hardware requirements not met"] : reasons)
        }
    }
}

// MARK: - ViewModel

class DashboardViewModel: ObservableObject {
    @Published var apps: [PatchableApp] = []
    @Published var log: [LogEntry] = []
    @Published var isBusy = false
    @Published var busyMessage = ""
    @Published var selected = Set<UUID>()

    func scan() {
        isBusy = true
        busyMessage = "Scanning /Applications…"
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppScanner.scan()
            DispatchQueue.main.async {
                self.apps = found
                self.isBusy = false
                self.busyMessage = ""
                self.append("Found \(found.count) app(s) requiring macOS 12+.", kind: .info)
            }
        }
    }

    func applyAll()    { operate(apps.filter { !$0.isPatched }, action: .apply) }
    func restoreAll()  { operate(apps.filter { $0.isPatched },  action: .restore) }
    func applySelected()   { operate(selectedApps().filter { !$0.isPatched }, action: .apply) }
    func restoreSelected() { operate(selectedApps().filter { $0.isPatched },  action: .restore) }

    private func selectedApps() -> [PatchableApp] { apps.filter { selected.contains($0.id) } }

    private enum Action { case apply, restore }

    private func operate(_ targets: [PatchableApp], action: Action) {
        guard !targets.isEmpty else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            for app in targets {
                DispatchQueue.main.async {
                    self.busyMessage = "\(action == .apply ? "Patching" : "Restoring") \(app.name)…"
                }
                do {
                    if action == .apply { try Patcher.apply(app: app) }
                    else               { try Patcher.restore(app: app) }
                    DispatchQueue.main.async {
                        self.updatePatched(id: app.id, patched: action == .apply)
                        self.append("\(action == .apply ? "Patched" : "Restored"): \(app.name)", kind: .success)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.append("Failed \(app.name): \(error.localizedDescription)", kind: .error)
                    }
                }
            }
            DispatchQueue.main.async { self.isBusy = false; self.busyMessage = "" }
        }
    }

    private func updatePatched(id: UUID, patched: Bool) {
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].isPatched = patched }
    }

    func append(_ msg: String, kind: LogEntry.Kind) {
        log.insert(LogEntry(date: Date(), message: msg, kind: kind), at: 0)
    }
}

// MARK: - App state / phases

enum Phase { case welcome, installing, dashboard }

class AppState: ObservableObject {
    @Published var phase: Phase = .welcome
    @Published var installProgress: Double = 0
    @Published var installStep = ""
    let vm = DashboardViewModel()

    func runInstall() {
        phase = .installing
        let steps: [(String, Double)] = [
            ("Verifying system requirements…", 0.15),
            ("Locating patch tools…",          0.30),
            ("Scanning /Applications…",        0.70),
            ("Building app list…",             0.90),
            ("Ready.",                         1.00),
        ]
        var delay = 0.0
        for (i, (label, progress)) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation { self.installProgress = progress }
                self.installStep = label
                if i == 2 {
                    self.vm.scan()
                }
                if i == steps.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation { self.phase = .dashboard }
                    }
                }
            }
            delay += (i == 2 ? 1.5 : 0.6)
        }
    }
}

// MARK: - Accent color helper (Big Sur compatible)

extension Color {
    static let accentBlue = Color.blue
    static let lightCyan  = Color(red: 0.2, green: 0.8, blue: 1.0)
}

// MARK: - Views

// ── Welcome ──────────────────────────────────────────────────────────────────

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 100, height: 100)
                    Image(systemName: "shield.checkmark.fill")
                        .resizable().scaledToFit()
                        .frame(width: 52, height: 52)
                        .foregroundColor(.blue)
                }
                Text("MacPatch Dashboard")
                    .font(.largeTitle).bold()
                Text("Run macOS 12+ apps on Big Sur without disabling\nSystem Integrity Protection.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 400)
            }
            Spacer()
            VStack(spacing: 10) {
                Button(action: { appState.runInstall() }) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 36)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                Text("Requires macOS 11 Big Sur · No SIP changes needed")
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
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 90, height: 90)
                Image(systemName: "shield.checkmark.fill")
                    .resizable().scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundColor(.blue)
            }
            VStack(spacing: 16) {
                Text("Setting up MacPatch…")
                    .font(.title2).bold()
                ProgressView(value: appState.installProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(width: 360)
                    .animation(.easeInOut(duration: 0.3), value: appState.installProgress)
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
    private var isSelected: Bool { selected.contains(app.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .blue : .secondary)
                .onTapGesture { toggle() }

            if let img = app.iconImage {
                Image(nsImage: img).resizable().scaledToFit().frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill").frame(width: 32, height: 32).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).fontWeight(.medium)
                Text(app.path)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Text("Requires \(app.requiredVersion)+")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .clipShape(Capsule())

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
        if isSelected { selected.remove(app.id) } else { selected.insert(app.id) }
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
            Spacer()
        }
    }
}

// ── Dashboard ─────────────────────────────────────────────────────────────────

struct DashboardView: View {
    @ObservedObject var vm: DashboardViewModel
    private var patchedCount:   Int { vm.apps.filter { $0.isPatched }.count }
    private var unpatchedCount: Int { vm.apps.filter { !$0.isPatched }.count }
    private var anySelected:    Bool { !vm.selected.isEmpty }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 12) {
                Image(systemName: "shield.checkmark.fill")
                    .font(.title2).foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacPatch Dashboard").font(.headline)
                    Text("\(patchedCount) patched · \(unpatchedCount) unpatched · \(vm.apps.count) total")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { vm.scan() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(vm.isBusy)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // App list
            if vm.apps.isEmpty && !vm.isBusy {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48)).foregroundColor(.green)
                    Text("No apps requiring macOS 12+ found.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(vm.apps) { app in
                    AppRow(app: app, selected: $vm.selected)
                }
                .listStyle(PlainListStyle())
            }

            Divider()

            // Toolbar
            VStack(spacing: 0) {
                if vm.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text(vm.busyMessage).font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.top, 8)
                }
                HStack(spacing: 10) {
                    Button(vm.selected.count == vm.apps.count ? "Deselect All" : "Select All") {
                        if vm.selected.count == vm.apps.count { vm.selected.removeAll() }
                        else { vm.selected = Set(vm.apps.map { $0.id }) }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .font(.caption).foregroundColor(.blue)

                    Spacer()

                    Button(action: { anySelected ? vm.restoreSelected() : vm.restoreAll() }) {
                        Label(anySelected ? "Restore Selected" : "Restore All",
                              systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .disabled(vm.isBusy || vm.apps.filter { $0.isPatched }.isEmpty)

                    Button(action: { anySelected ? vm.applySelected() : vm.applyAll() }) {
                        Label(anySelected ? "Patch Selected" : "Patch All",
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(vm.isBusy || vm.apps.filter { !$0.isPatched }.isEmpty
                                ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .disabled(vm.isBusy || vm.apps.filter { !$0.isPatched }.isEmpty)
                }
                .padding()
            }
            .background(Color(NSColor.windowBackgroundColor))

            // Log
            if !vm.log.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(vm.log) { LogRow(entry: $0) }
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
                .frame(height: 100)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
            }
        }
    }
}

// ── Root ──────────────────────────────────────────────────────────────────────

struct RootView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        Group {
            switch appState.phase {
            case .welcome:    WelcomeView()
            case .installing: InstallView()
            case .dashboard:  MainTabView(vm: appState.vm)
            }
        }
        .frame(minWidth: 660, minHeight: 500)
    }
}

// MARK: - Store ViewModel

class StoreViewModel: ObservableObject {
    @Published var plugins: [StorePlugin] = []
    @Published var isChecking = false

    func loadAndVerify() {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded = Store.loadPlugins()
            for i in loaded.indices {
                let (verdict, reasons) = Store.runGate(loaded[i])
                loaded[i].gateVerdict = verdict
                loaded[i].gateReasons = reasons
            }
            DispatchQueue.main.async {
                self.plugins = loaded
                self.isChecking = false
            }
        }
    }
}

// MARK: - Store views

struct GateBadge: View {
    let verdict: GateVerdict
    var body: some View {
        switch verdict {
        case .pass:
            return AnyView(Label("Compatible", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold)).foregroundColor(.green))
        case .block:
            return AnyView(Label("Not compatible", systemImage: "xmark.seal.fill")
                .font(.caption.weight(.semibold)).foregroundColor(.red))
        case .unknown:
            return AnyView(Label("Checking…", systemImage: "hourglass")
                .font(.caption).foregroundColor(.secondary))
        }
    }
}

struct StoreRow: View {
    let plugin: StorePlugin
    let onBuy: (StorePlugin) -> Void

    private var canBuy: Bool { plugin.gateVerdict == .pass }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline)
                    Text("\(plugin.vendor) · \(plugin.category)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                GateBadge(verdict: plugin.gateVerdict)
            }

            Text("Requires \(plugin.minRamGB) GB RAM · \(plugin.minCores) CPU cores"
                 + (plugin.archReq == "any" ? "" : " · \(plugin.archReq)"))
                .font(.caption).foregroundColor(.secondary)

            if plugin.gateVerdict == .block && !plugin.gateReasons.isEmpty {
                ForEach(plugin.gateReasons, id: \.self) { r in
                    Label(r, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundColor(.red)
                }
            }

            HStack {
                Spacer()
                Button(action: { onBuy(plugin) }) {
                    Text(canBuy ? "Buy & Patch" : "Blocked")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(canBuy ? Color.blue : Color.gray)
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!canBuy)   // hard block: purchase impossible when gate fails
            }
        }
        .padding(.vertical, 8)
    }
}

struct StoreView: View {
    @ObservedObject var store: StoreViewModel
    @ObservedObject var vm: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Store").font(.headline)
                    Text("Every patch is checked against this Mac's CPU & RAM before purchase")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if store.isChecking { ProgressView().scaleEffect(0.7) }
                Button(action: { store.loadAndVerify() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(store.isChecking)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if store.plugins.isEmpty && !store.isChecking {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "bag").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("No plugins found in the bundle.").foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(store.plugins) { p in
                    StoreRow(plugin: p, onBuy: buy)
                }
                .listStyle(PlainListStyle())
            }
        }
        .onAppear { if store.plugins.isEmpty { store.loadAndVerify() } }
    }

    // Purchase + patch. The gate already passed to enable this button; patch-app.sh
    // re-runs the gate at install time as a second, independent enforcement.
    private func buy(_ plugin: StorePlugin) {
        guard plugin.gateVerdict == .pass else { return }
        vm.append("Purchasing \(plugin.name)…", kind: .info)
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = Store.probePath()
            let script = Patcher.scriptPath()
            // Pass the plugin so patch-app.sh enforces the gate again at install time.
            let cmd = "'\(script)' apply '\(plugin.appPath)' '\(plugin.filePath)'"
            do {
                _ = try runPrivileged(cmd)
                DispatchQueue.main.async {
                    vm.append("Installed & patched: \(plugin.name)", kind: .success)
                    vm.scan()
                }
            } catch {
                DispatchQueue.main.async {
                    vm.append("Patch refused for \(plugin.name): \(error.localizedDescription)", kind: .error)
                }
            }
            _ = probe
        }
    }
}

// MARK: - Tabbed container

struct MainTabView: View {
    @ObservedObject var vm: DashboardViewModel
    @StateObject private var store = StoreViewModel()
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("My Apps").tag(0)
                Text("Store").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal).padding(.top, 10).padding(.bottom, 6)

            Divider()

            if tab == 0 {
                DashboardView(vm: vm)
            } else {
                StoreView(store: store, vm: vm)
            }
        }
    }
}

// MARK: - Entry point (AppKit-based for single-file swiftc compatibility)

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = RootView().environmentObject(appState)
        let hosting  = NSHostingView(rootView: content)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window?.title          = "MacPatch Dashboard"
        window?.contentView    = hosting
        window?.setFrameAutosaveName("MacPatchMain")
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
