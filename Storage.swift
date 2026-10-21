// Storage (what fills the disk, with git worktrees in detail) and Usage (who used the CPU over time).

import AppKit
import SwiftUI

// MARK: - Storage model

struct WorktreeInfo: Identifiable {
    var id: String { path }
    let repo: String   // the main checkout
    let path: String
    let branch: String
    var size: UInt64 = 0
    var lastUsed: Date?
    var dirty = false
    var merged = false
    var missing = false
    var inUse = false
    /// Removing it loses nothing: no uncommitted work, no session in it.
    var removable: Bool { !dirty && !inUse && !missing }
}

struct StorageBucket: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let paths: [URL]
    var size: UInt64?
}

final class StorageScanner: ObservableObject {
    @Published var worktrees: [WorktreeInfo] = []
    @Published var buckets: [StorageBucket] = []
    @Published var scanning = false
    @Published var working = false
    @Published var lastScan: Date?
    @Published var message: String?
    @Published var selected = Set<String>()
    /// Working folders of running agent sessions, so their worktrees are never offered for removal.
    var sessionFolders: () -> [String] = { [] }

    private let queue = DispatchQueue(label: "nabd.storage", qos: .utility)
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var worktreeTotal: UInt64 { worktrees.reduce(0) { $0 + $1.size } }
    var selectedSize: UInt64 { worktrees.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }

    // MARK: Shell helpers

    @discardableResult
    private static func run(_ tool: String, _ args: [String], in dir: String? = nil) -> (status: Int32, out: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        if let dir { task.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func git(_ args: [String], in dir: String) -> (status: Int32, out: String) {
        run("/usr/bin/git", ["-C", dir] + args)
    }

    static func diskUsage(_ path: String) -> UInt64 {
        let out = run("/usr/bin/du", ["-sk", path]).out
        return (UInt64(out.split(separator: "\t").first ?? "") ?? 0) * 1024
    }

    // MARK: Scan

    /// Main checkouts under the home folder (and common local web roots), plus the repos of running sessions.
    private func repositories() -> [String] {
        var roots = [home.path]
        for extra in ["/Applications/XAMPP/xamppfiles/htdocs", "/opt/homebrew/var/www", "/Library/WebServer/Documents"]
        where FileManager.default.fileExists(atPath: extra) { roots.append(extra) }
        var repos = Set<String>()
        for root in roots {
            let out = StorageScanner.run("/usr/bin/find", [root, "-maxdepth", "5",
                "(", "-name", "Library", "-o", "-name", "node_modules", "-o", "-name", "vendor", "-o", "-name", ".Trash",
                "-o", "-name", ".npm", "-o", "-name", "worktrees", "-o", "-name", "Pods", ")", "-prune",
                "-o", "-name", ".git", "-type", "d", "-print"]).out
            for line in out.split(separator: "\n") { repos.insert(String(line.dropLast(5))) }
        }
        for folder in sessionFolders() {
            let common = StorageScanner.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if common.hasSuffix("/.git") { repos.insert(String(common.dropLast(5))) }
        }
        return repos.sorted()
    }

    private func defaultBranch(_ repo: String) -> String? {
        let head = StorageScanner.git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { return head }
        for name in ["main", "master", "develop"] where StorageScanner.git(["rev-parse", "--verify", "--quiet", name], in: repo).status == 0 { return name }
        return nil
    }

    func scan() {
        guard !scanning, !working else { return }
        scanning = true
        let sessions = sessionFolders()
        queue.async {
            var found: [WorktreeInfo] = []
            for repo in self.repositories() {
                let porcelain = StorageScanner.git(["worktree", "list", "--porcelain"], in: repo).out
                var merged = Set<String>()
                if let base = self.defaultBranch(repo) {
                    merged = Set(StorageScanner.git(["branch", "--format=%(refname:short)", "--merged", base], in: repo).out
                        .split(separator: "\n").map(String.init))
                }
                var path = "", branch = "", missing = false
                for line in (porcelain + "\n").split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                    else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                    else if line.hasPrefix("detached") { branch = "" }
                    else if line.hasPrefix("prunable") { missing = true }
                    else if line.isEmpty, !path.isEmpty {
                        if path != repo {
                            var w = WorktreeInfo(repo: repo, path: path, branch: branch)
                            w.missing = missing || !FileManager.default.fileExists(atPath: path)
                            w.merged = !branch.isEmpty && merged.contains(branch)
                            w.inUse = sessions.contains { $0 == path || $0.hasPrefix(path + "/") }
                            found.append(w)
                        }
                        path = ""; branch = ""; missing = false
                    }
                }
            }
            // Measure in parallel into separate slots; the array itself is only touched on this thread.
            let measured = UnsafeMutableBufferPointer<(size: UInt64, dirty: Bool, lastUsed: Date?)>.allocate(capacity: found.count)
            measured.initialize(repeating: (0, false, nil))
            defer { measured.deallocate() }
            let targets = found.map { ($0.path, $0.missing) }
            DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                let (path, missing) = targets[i]
                guard !missing else { return }
                let size = StorageScanner.diskUsage(path)
                let dirty = !StorageScanner.git(["status", "--porcelain"], in: path).out.isEmpty
                // The worktree's own index changes whenever git works in it: the best "last used" signal.
                let gitFile = (try? String(contentsOfFile: path + "/.git", encoding: .utf8)) ?? ""
                let gitDir = gitFile.hasPrefix("gitdir: ") ? gitFile.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines) : path + "/.git"
                let index = (try? FileManager.default.attributesOfItem(atPath: gitDir + "/index"))?[.modificationDate] as? Date
                measured[i] = (size, dirty, index ?? (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
            }
            for i in found.indices {
                found[i].size = measured[i].size
                found[i].dirty = measured[i].dirty
                found[i].lastUsed = measured[i].lastUsed
            }
            var buckets = self.bucketList()
            for i in buckets.indices {
                buckets[i].size = buckets[i].paths.filter { FileManager.default.fileExists(atPath: $0.path) }
                    .reduce(UInt64(0)) { $0 + StorageScanner.diskUsage($1.path) }
            }
            let total = found.reduce(UInt64(0)) { $0 + $1.size }
            UserDefaults.standard.set(Double(total), forKey: "worktreeBytes")
            UserDefaults.standard.set(found.count, forKey: "worktreeCount")
            DispatchQueue.main.async {
                self.worktrees = found.sorted { $0.size > $1.size }
                self.buckets = buckets
                self.selected.formIntersection(found.filter(\.removable).map(\.id))
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    private func bucketList() -> [StorageBucket] {
        let lib = home.appendingPathComponent("Library")
        return [
            StorageBucket(id: "downloads", title: L("Downloads"), symbol: "arrow.down.circle", paths: [home.appendingPathComponent("Downloads")]),
            StorageBucket(id: "trash", title: L("Trash"), symbol: "trash", paths: [home.appendingPathComponent(".Trash")]),
            StorageBucket(id: "xcode", title: L("Xcode and simulators"), symbol: "hammer", paths: [lib.appendingPathComponent("Developer")]),
            StorageBucket(id: "caches", title: L("Caches"), symbol: "shippingbox",
                          paths: [lib.appendingPathComponent("Caches"), home.appendingPathComponent(".npm"), home.appendingPathComponent(".cache")]),
            StorageBucket(id: "docker", title: "Docker", symbol: "cube", paths: [lib.appendingPathComponent("Containers/com.docker.docker/Data")]),
            StorageBucket(id: "ios", title: L("iPhone backups"), symbol: "iphone", paths: [lib.appendingPathComponent("Application Support/MobileSync/Backup")]),
        ]
    }

    // MARK: Remove

    /// Clean worktrees: the folder goes to the Trash (so it can be put back) and git forgets it. Branches stay.
    func removeSelected() {
        let chosen = worktrees.filter { selected.contains($0.id) && $0.removable }
        guard !chosen.isEmpty, !working else { return }
        let alert = NSAlert()
        alert.messageText = L("Move %@ worktrees to the Trash?", String(chosen.count))
        alert.informativeText = L("They take %@. Their branches and commits stay in the repository; only the working folders go, and you can put them back from the Trash.",
                                  fmtDisk(chosen.reduce(0) { $0 + $1.size }))
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        working = true
        message = nil
        queue.async {
            var moved: UInt64 = 0, failures: [String] = []
            for w in chosen {
                // Re-check right before acting: something may have changed since the scan.
                if !StorageScanner.git(["status", "--porcelain"], in: w.path).out.isEmpty { failures.append(w.path); continue }
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: w.path), resultingItemURL: nil)
                    moved += w.size
                } catch { failures.append(w.path) }
            }
            for repo in Set(chosen.map(\.repo)) { StorageScanner.git(["worktree", "prune"], in: repo) }
            DispatchQueue.main.async {
                self.working = false
                self.selected.removeAll()
                var text = L("Moved %@ to the Trash. Empty the Trash to get the space back.", fmtDisk(moved))
                if !failures.isEmpty { text += " " + L("Skipped: %@.", failures.map { ($0 as NSString).lastPathComponent }.joined(separator: L(", "))) }
                self.message = text
                self.scan()
            }
        }
    }

    /// Forget worktrees whose folders are already gone.
    func pruneMissing() {
        let repos = Set(worktrees.filter(\.missing).map(\.repo))
        queue.async {
            for repo in repos { StorageScanner.git(["worktree", "prune"], in: repo) }
            DispatchQueue.main.async { self.scan() }
        }
    }

    func selectStale(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        selected = Set(worktrees.filter { $0.removable && $0.merged && ($0.lastUsed ?? .distantPast) < cutoff }.map(\.id))
    }
}

// MARK: - Usage (CPU time per app, kept for a week)

final class UsageTracker {
    /// Hour number since 1970 → app → CPU seconds.
    private var hours: [Int: [String: Double]] = [:]
    private var lastSample: Date?
    private var savedAt = Date()
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nabd")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }()

    init() { load() }

    /// One process scan: each app's CPU share times the time since the previous scan.
    func record(_ groups: [ProcGroup], at now: Date = Date()) {
        defer { lastSample = now }
        guard let last = lastSample else { return }
        let seconds = min(now.timeIntervalSince(last), 120)  // gaps (sleep, Nabd closed) are not guessed
        let hour = Int(now.timeIntervalSince1970 / 3600)
        for g in groups where g.cpu >= 1 { hours[hour, default: [:]][g.name, default: 0] += g.cpu / 100 * seconds }
        let oldest = hour - 24 * 7
        hours = hours.filter { $0.key > oldest }
        if now.timeIntervalSince(savedAt) > 300 { save(); savedAt = now }
    }

    func top(hoursBack: Int, limit: Int = 12) -> [(name: String, seconds: Double)] {
        let from = Int(Date().timeIntervalSince1970 / 3600) - hoursBack + 1
        var sum: [String: Double] = [:]
        for (hour, apps) in hours where hour >= from { for (name, s) in apps { sum[name, default: 0] += s } }
        return sum.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    func save() {
        let plain = Dictionary(uniqueKeysWithValues: hours.map { (String($0.key), $0.value) })
        if let data = try? JSONSerialization.data(withJSONObject: plain) { try? data.write(to: file, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), let plain = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else { return }
        hours = Dictionary(uniqueKeysWithValues: plain.compactMap { k, v in Int(k).map { ($0, v) } })
    }
}

/// "3h 12m of CPU", "45m", "30s".
func fmtCPUTime(_ seconds: Double) -> String {
    if seconds >= 3600 { return String(format: "%.0fh %02.0fm", (seconds / 3600).rounded(.down), (seconds.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down)) }
    if seconds >= 60 { return String(format: "%.0fm", (seconds / 60).rounded(.down)) }
    return String(format: "%.0fs", seconds)
}

// MARK: - Pages

struct StoragePage: View {
    @ObservedObject var storage: StorageScanner
    @State private var expanded = Set<String>()

    private var projects: [(repo: String, items: [WorktreeInfo], size: UInt64)] {
        Dictionary(grouping: storage.worktrees, by: \.repo)
            .map { ($0.key, $0.value.sorted { $0.size > $1.size }, $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.size > $1.size }
    }

    var body: some View {
        let free = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]))
        let freeBytes = free?.volumeAvailableCapacityForImportantUsage.map(UInt64.init) ?? 0
        let totalBytes = free?.volumeTotalCapacity.map(UInt64.init) ?? 0
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Free")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(ltr(fmtDisk(freeBytes))).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(rtl(L("of %@", ltr(fmtDisk(totalBytes))))).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if storage.scanning || storage.working { ProgressView().controlSize(.small) }
                    Button(L("Scan Again")) { storage.scan() }.disabled(storage.scanning || storage.working)
                }
                if totalBytes > 0 {
                    GeometryReader { geo in
                        Capsule().fill(Color.primary.opacity(0.08)).overlay(alignment: .leading) {
                            Capsule().fill(Double(freeBytes) < Double(totalBytes) * 0.08 ? Color.orange : Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(totalBytes - min(freeBytes, totalBytes)) / CGFloat(totalBytes))
                        }
                    }
                    .frame(height: 8)
                }
                if let lastScan = storage.lastScan {
                    Text(rtl(L("Measured %@ ago", fmtDuration(Date().timeIntervalSince(lastScan))))).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Card {
                smallTitle(L("Large folders"))
                ForEach(storage.buckets.filter { ($0.size ?? 0) > 0 }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }) { b in
                    HStack {
                        Label(b.title, systemImage: b.symbol).font(.system(size: 12))
                        Spacer()
                        Text(ltr(b.size.map(fmtDisk) ?? "—")).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Button { NSWorkspace.shared.activateFileViewerSelecting(b.paths) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless).help(L("Show in Finder")).accessibilityLabel(L("Show in Finder"))
                    }
                    .modifier(HoverRow())
                }
                if storage.buckets.isEmpty && storage.scanning { Text(L("Measuring…")).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            worktreeCard
        }
    }

    private var worktreeCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    smallTitle(L("Git worktrees"))
                    Text(rtl(L("%@ worktrees · %@", String(storage.worktrees.count), ltr(fmtDisk(storage.worktreeTotal)))))
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Button(L("Select Merged, Unused 7+ Days")) { storage.selectStale(days: 7) }.disabled(storage.worktrees.isEmpty)
                Button(L("Move Selected to Trash…")) { storage.removeSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(storage.selected.isEmpty || storage.working)
            }
            Text(L("AI sessions often leave a worktree per task, each with its own node_modules or vendor. Only worktrees with no uncommitted changes and no running session can be selected. Branches and commits stay; folders go to the Trash."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !storage.selected.isEmpty {
                Text(rtl(L("Selected: %@ (%@)", String(storage.selected.count), ltr(fmtDisk(storage.selectedSize))))).font(.system(size: 12, weight: .medium))
            }
            if let message = storage.message { Text(rtl(message)).font(.system(size: 12)).foregroundStyle(.green) }
            if storage.worktrees.contains(where: \.missing) {
                HStack {
                    Text(L("Some worktrees point to folders that no longer exist.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L("Clean Up List")) { storage.pruneMissing() }.controlSize(.small)
                }
            }
            ForEach(projects, id: \.repo) { project in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(project.repo) },
                                                    set: { if $0 { expanded.insert(project.repo) } else { expanded.remove(project.repo) } })) {
                    ForEach(project.items) { w in row(w) }
                } label: {
                    HStack {
                        Text(ltr((project.repo as NSString).lastPathComponent)).font(.system(size: 13, weight: .medium))
                        Text(ltr(project.repo)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text(rtl(L("%@ worktrees", String(project.items.count)))).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(ltr(fmtDisk(project.size))).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func row(_ w: WorktreeInfo) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { storage.selected.contains(w.id) },
                                     set: { if $0 { storage.selected.insert(w.id) } else { storage.selected.remove(w.id) } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!w.removable)
            VStack(alignment: .leading, spacing: 1) {
                Text(ltr((w.path as NSString).lastPathComponent)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if !w.branch.isEmpty { Text(ltr(w.branch)).lineLimit(1).truncationMode(.middle) }
                    if let used = w.lastUsed { Text(rtl(L("used %@ ago", fmtDuration(Date().timeIntervalSince(used))))) }
                    if w.inUse { badge(L("open in a session"), .accentColor) }
                    if w.dirty { badge(L("uncommitted changes"), .orange) }
                    if w.merged { badge(L("merged"), .green) }
                    if w.missing { badge(L("folder missing"), .secondary) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ltr(fmtDisk(w.size))).font(.system(size: 12)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help(L("Show in Finder")).accessibilityLabel(L("Show in Finder")).disabled(w.missing)
        }
        .modifier(HoverRow())
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }
}

struct UsagePage: View {
    let tracker: UsageTracker
    @ObservedObject var model: Model  // only to refresh as new readings arrive
    @State private var span = 1

    var body: some View {
        let hours = [1, 24, 24 * 7][span]
        let rows = tracker.top(hoursBack: hours)
        let total = rows.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack {
                    smallTitle(L("Who used the CPU"))
                    Spacer()
                    Picker("", selection: $span) {
                        Text(L("Last hour")).tag(0)
                        Text(L("Today")).tag(1)
                        Text(L("7 days")).tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(L("CPU time each app used while Nabd was running. One hour of CPU means one core busy for an hour."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text(L("Collecting… check back in a few minutes.")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        Text(ltr(row.name)).font(.system(size: 12)).lineLimit(1).frame(width: 200, alignment: .leading)
                        GeometryReader { geo in
                            Capsule().fill(Color.accentColor.opacity(0.85))
                                .frame(width: max(2, geo.size.width * CGFloat(row.seconds / max(rows.first?.seconds ?? 1, 1))))
                        }
                        .frame(height: 8)
                        Text(ltr(fmtCPUTime(row.seconds))).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(ltr(String(format: "%.0f%%", total > 0 ? row.seconds / total * 100 : 0))).font(.system(size: 11)).foregroundStyle(.secondary)
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    .modifier(HoverRow())
                }
            }
        }
    }
}
