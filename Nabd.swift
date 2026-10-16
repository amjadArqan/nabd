// Nabd — a light menu bar monitor for temperature, CPU, GPU, memory, network, disk and power on macOS,
// with a focus on Claude Code sessions and background dev services. English is the base language;
// translations live in Localization/<language>.lproj/Localizable.strings.
//
// Build: ./build.sh      GUI: open Nabd.app      CLI: ./nabd status | doctor | json | line

import AppKit
import SwiftUI
import IOKit
import ServiceManagement
import UserNotifications
import Charts

// MARK: - Small helpers

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

func fmtBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_048_576)
}

// MARK: Localization

/// The app bundle, also when the binary runs through a symlink such as `./nabd` (then Bundle.main is the link's folder).
let appBundle: Bundle = {
    if Bundle.main.bundleURL.pathExtension == "app" { return .main }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? Bundle(url: app) ?? .main : .main
}()

/// The language macOS picked for this app from the user's preferred languages and the ones we ship.
let appLanguage = appBundle.preferredLocalizations.first ?? "en"
let isRTL = Locale.Language(identifier: appLanguage).characterDirection == .rightToLeft
/// Latin digits everywhere, so numbers read the same next to units like GB and W.
let appLocale = Locale(identifier: appLanguage + "@numbers=latn")

/// English text is the key; a missing translation falls back to it.
func L(_ key: String) -> String { appBundle.localizedString(forKey: key, value: key, table: nil) }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), locale: appLocale, arguments: args) }

private let durationFormatter: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    f.allowedUnits = [.day, .hour, .minute]
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = appLocale
    f.calendar = calendar
    return f
}()

/// "2d 3h" in the app's language; `localized: false` keeps plain English units for the terminal.
func fmtDuration(_ t: TimeInterval, localized: Bool = true) -> String {
    if localized, let text = durationFormatter.string(from: max(60, t)) { return text }
    let s = max(0, Int(t))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

/// Bytes per second, compact for the menu bar ("1.2M") or spelled out for the panel ("1.2 MB/s").
func fmtRate(_ bytes: Double, short: Bool = false) -> String {
    let mb = bytes / 1_048_576
    if short { return mb >= 1 ? String(format: "%.1fM", mb) : String(format: "%.0fK", bytes / 1024) }
    return mb >= 1 ? String(format: "%.1f MB/s", mb) : String(format: "%.0f KB/s", bytes / 1024)
}

/// Storage in decimal units, as Finder shows it.
func fmtDisk(_ b: UInt64) -> String {
    let gb = Double(b) / 1e9
    return gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb)
}

func fmtPct(_ v: Double) -> String { String(format: "%.0f%%", v) }

/// Isolates a left-to-right run (numbers, units, process names) inside right-to-left text.
func ltr(_ s: String) -> String { "\u{2066}\(s)\u{2069}" }

/// Text takes its base direction from its first strong character; in a right-to-left language this pins
/// sentences that start with a Latin name ("Spotlight …") to right-to-left. A no-op otherwise.
func rtl(_ s: String) -> String { isRTL ? "\u{200F}" + s : s }

// MARK: - Model types

enum Level: Int, Comparable {
    case ok = 0, warn, crit
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Fan {
    var rpm: Double, min: Double, max: Double
    var fraction: Double { max > min ? Swift.min(1, Swift.max(0, (rpm - min) / (max - min))) : 0 }
}

struct Temps {
    var cpu: Double?
    var cpuMax: Double?
    var gpu: Double?
    var battery: Double?
    var ssd: Double?
    var fans: [Fan] = []
}

struct MemInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure = 1  // 1 normal, 2 warning, 4 critical
    var used: UInt64 { app + wired + compressed }
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

/// Power as the battery controller reports it (no sudo needed). All values in watts.
struct PowerInfo {
    var plugged = false
    var charging = false
    var adapterWatts: Double?  // what the charger is rated for: the most the Mac can pull from it
    var adapterName: String?
    var input: Double?         // drawn from the charger right now
    var system: Double?        // used by the Mac itself
    var battery: Double?       // into the battery (+) or out of it (−)
    var loss: Double?          // lost as heat inside the charger
    var percent: Int?
    var minutesLeft: Int?
    var health: Double?        // full-charge capacity as a percent of the design capacity
    var cycles: Int?
    /// What the wall socket delivers: the charger's output plus its own loss.
    var wall: Double? { plugged ? input.map { $0 + (loss ?? 0) } : nil }
    /// The headline number: from the wall when plugged in, otherwise what the battery is feeding the Mac.
    var draw: Double? { wall ?? system ?? battery.map { abs($0) } }
}

struct HistoryPoint: Identifiable {
    var id: Date { time }
    let time: Date
    let cpu: Double
    let gpu: Double?
    let temp: Double?
    let mem: Double
    let power: Double?
    let netIn: Double?
    let netOut: Double?
}

struct Proc {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let pri: Int
    let cpu: Double  // percent of one core, as in Activity Monitor
    let mem: UInt64
    let elapsed: TimeInterval
    let cpuTime: TimeInterval
    let name: String
    let path: String
    let command: String
    /// The kernel clamps background-band processes to priority 4; it does not report the band for other pids.
    var calm: Bool { pri <= 4 }
}

struct ProcGroup: Identifiable {
    var id: String { name }
    var name: String
    var cpu = 0.0
    var mem: UInt64 = 0
    var pids: [Int32] = []
    var mine = true
    var calm = true
}

struct ClaudeSession: Identifiable {
    let id: Int32
    var label: String
    var cwd: String
    var elapsed: TimeInterval
    var cpu: Double
    var mem: UInt64
    var pids: [Int32]
    var mcpCount: Int
    var topName: String?
    var topCPU = 0.0
    var quietFor: TimeInterval = 0
    var idle = false
    var calm = false
}

struct ProcReport {
    var total = 0
    var groups: [ProcGroup] = []
    var sessions: [ClaudeSession] = []
    var mcpCount = 0
    var mcpMem: UInt64 = 0
    var orphanMCP: [Proc] = []
    var runaway: [Proc] = []
    var desktop: ProcGroup? { groups.first { $0.name == "Claude" } }
}

struct Advice: Identifiable {
    let id: String
    let level: Level
    let title: String
    let detail: String
    var killPids: [Int32] = []
}

struct Snapshot {
    var cpuTotal = 0.0
    var cpuP: Double?
    var cpuE: Double?
    var load: [Double] = [0, 0, 0]
    var ncpu = 1
    var mem = MemInfo()
    var temps = Temps()
    var thermal = ProcessInfo.ThermalState.nominal
    var uptime: TimeInterval = 0
    var power: PowerInfo?
    var gpu: Double?          // percent busy
    var netIn: Double?        // bytes per second
    var netOut: Double?
    var diskRead: Double?     // bytes per second
    var diskWrite: Double?
    var diskFree: UInt64?
    var diskTotal: UInt64?
    var procs: ProcReport?
    var advice: [Advice] = []

    var tempLevel: Level {
        if thermal == .serious || thermal == .critical { return .crit }
        if let t = temps.cpu, t >= 95 { return .crit }
        if let t = temps.cpu, t >= 80 { return .warn }
        return thermal == .fair ? .warn : .ok
    }
    var cpuLevel: Level {
        if cpuTotal >= 95, load[0] / Double(ncpu) >= 4 { return .crit }
        return cpuTotal >= 85 ? .warn : .ok
    }
    var memLevel: Level { mem.pressure >= 4 ? .crit : (mem.pressure >= 2 ? .warn : .ok) }
    var level: Level { max(tempLevel, cpuLevel, memLevel) }
}

extension ProcessInfo.ThermalState {
    var localized: String {
        switch self {
        case .nominal: return L("Normal")
        case .fair: return L("Warm")
        case .serious: return L("Hot")
        case .critical: return L("Critical")
        @unknown default: return "?"
        }
    }
    var english: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - SMC (CPU/GPU core temperatures and fans; no sudo needed)

final class SMC {
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]
    private(set) var cpuKeys: [UInt32] = []
    private(set) var gpuKeys: [UInt32] = []
    private var fanInfo: [(key: UInt32, min: Double, max: Double)] = []

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func name(_ k: UInt32) -> String {
        String(bytes: [UInt8(k >> 24), UInt8((k >> 16) & 0xff), UInt8((k >> 8) & 0xff), UInt8(k & 0xff)], encoding: .ascii) ?? "?"
    }

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
        discover()
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    func read(_ key: UInt32) -> Double? {
        var input = KeyData()
        input.key = key
        let info: (size: UInt32, type: UInt32)
        if let cached = infoCache[key] {
            info = cached
        } else {
            input.data8 = 9
            guard let out = call(&input) else { return nil }
            info = (out.keyInfo.dataSize, out.keyInfo.dataType)
            infoCache[key] = info
        }
        input.keyInfo.dataSize = info.size
        input.data8 = 5
        guard let out = call(&input) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.size))) }
        switch SMC.name(info.type) {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2" where b.count == 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 " where b.count == 1: return Double(b[0])
        case "ui32" where b.count == 4: return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default: return nil
        }
    }

    /// Core sensor keys differ per chip generation, so enumerate them once instead of hardcoding.
    private func discover() {
        guard let count = read(SMC.fourCC("#KEY")) else { return }
        var alt: [UInt32] = []
        for i in 0..<UInt32(count) {
            var input = KeyData()
            input.data8 = 8
            input.data32 = i
            guard let key = call(&input)?.key, key >> 24 == 0x54 else { continue }  // "T…"
            guard let v = read(key), let type = infoCache[key]?.type, ["flt ", "sp78"].contains(SMC.name(type)) else { continue }
            guard v > 5, v < 130 else { continue }
            switch UInt8((key >> 16) & 0xff) {
            case 0x70, 0x65: cpuKeys.append(key)  // Tp… / Te…
            case 0x67: gpuKeys.append(key)        // Tg…
            case 0x66: alt.append(key)            // Tf… (M3 family)
            default: break
            }
        }
        if cpuKeys.isEmpty { cpuKeys = alt }
        let fans = Int(read(SMC.fourCC("FNum")) ?? 0)
        for i in 0..<min(fans, 4) {
            fanInfo.append((SMC.fourCC("F\(i)Ac"), read(SMC.fourCC("F\(i)Mn")) ?? 0, read(SMC.fourCC("F\(i)Mx")) ?? 0))
        }
    }

    func values(_ keys: [UInt32]) -> [Double] { keys.compactMap { read($0) }.filter { $0 >= 20 && $0 < 130 } }
    func fans() -> [Fan] { fanInfo.compactMap { f in read(f.key).map { Fan(rpm: $0, min: f.min, max: f.max) } } }
}

// MARK: - HID sensors (battery, SSD, and a CPU fallback when SMC keys are unknown)

final class HIDTemps {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let services: CFArray  // keeps the service clients alive
    private var sensors: [(name: String, service: OpaquePointer)] = []

    init?() {
        let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault) else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = copyServices(client)?.takeRetainedValue() else { return nil }
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.services = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let service = OpaquePointer(raw)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            sensors.append((name, service))
        }
    }

    func read(_ wanted: (String) -> Bool) -> [(name: String, value: Double)] {
        sensors.compactMap { sensor in
            guard wanted(sensor.name), let event = copyEvent(sensor.service, 15, 0, 0) else { return nil }
            defer { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release() }
            let v = getFloat(event, 15 << 16)
            return v > 5 && v < 130 ? (sensor.name, v) : nil
        }
    }
}

// MARK: - Process priority ("calm" = Darwin background: efficiency cores, throttled I/O)

enum Priority {
    static func set(_ pids: [Int32], background: Bool) {
        for pid in pids where pid > 1 { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0) }
    }
}

// MARK: - Guard (pauses the heaviest Claude Code session while the CPU is saturated)

/// Sessions run at full speed until the whole machine has stayed at the limit for a few looks in a row. Then the
/// session whose jobs burn the most CPU is paused: SIGSTOP on its busy job processes, never on `claude` itself
/// or its MCP servers. It continues on its own once the machine has calmed down, or at once on a forced continue.
/// Processes are read through libproc, so a look costs about a millisecond.
final class Guard {
    struct Paused: Equatable {
        let root: Int32
        var since: Date
        var manual: Bool  // paused by the user: stays paused until they continue it
        var hot: Bool     // paused for temperature rather than load
    }
    struct Status: Equatable {
        var cpu = 0.0
        var paused: [Paused] = []
        var exempt: [Int32] = []  // force-continued sessions, immune for a while
    }
    struct Input {
        var limit = 0  // system CPU % at which the heaviest session is paused; 0 = off
        var temp: Double?
        var thermal = ProcessInfo.ThermalState.nominal
    }
    private struct Info {
        let ppid: Int32, start: UInt64, name: String
    }
    struct Event {
        let date: Date, root: Int32, what: String
    }

    static let interval = 3.0                   // seconds between looks
    static let sustain = 4                      // looks at the limit before pausing (~12 s)
    static let relief = 3                       // looks well under the limit before continuing (~9 s)
    static let margin = 15.0                    // "well under" = this many points below the limit
    static let minimumPause: TimeInterval = 30
    static let maximumPause: TimeInterval = 300 // nobody waits longer than this; sessions take turns instead
    static let grace: TimeInterval = 60         // a session that just continued cannot be paused again this soon
    static let exemption: TimeInterval = 15 * 60
    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish"]

    /// Decide but do not touch any process (used by `nabd guard`).
    var dryRun = false
    /// Remember stopped processes across launches, so a crash or force-quit cannot leave jobs frozen for good.
    var persist = false
    /// Cores each session's jobs were using at the last look.
    private(set) var demand: [Int32: Double] = [:]

    private let host = mach_host_self()
    private var lastHost: [UInt32] = []
    private var lastCPU: [Int32: UInt64] = [:]
    private var lastStamp: UInt64 = 0
    private var jobs: [Int32: [(pid: Int32, cores: Double)]] = [:]
    private var stopped: [Int32: Set<Int32>] = [:]  // session root → job pids we stopped
    private var paused: [Int32: Paused] = [:]
    private var manual = Set<Int32>()
    private var immuneUntil: [Int32: Date] = [:]
    private var exemptUntil: [Int32: Date] = [:]
    private var pressure = 0, calm = 0
    private var adopted = false
    private var saved = Set<Int32>()
    private var lastStatus = Status()
    private var events: [Event] = []
    private let nanosPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// Hands over what happened since the last call (pauses and continues, each with its reason).
    func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    private func processes() -> [Int32: Info] {
        var pids = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride)))
        let myUID = getuid()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        var out: [Int32: Info] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 1 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.pbi_uid == myUID else { continue }
            var name = withUnsafeBytes(of: bsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name.isEmpty { name = withUnsafeBytes(of: bsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
            out[pid] = Info(ppid: Int32(bsd.pbi_ppid), start: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec, name: name)
        }
        return out
    }

    private func cpuNanos(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? UInt64(Double(info.ri_user_time + info.ri_system_time) * nanosPerTick) : nil
    }

    /// Whole-machine CPU use since the previous look.
    private func systemCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let now = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastHost = now }
        guard lastHost.count == now.count else { return nil }
        let delta = zip(now, lastHost).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? (total - delta[Int(CPU_STATE_IDLE)]) / total * 100 : nil
    }

    private func signal(_ pid: Int32, _ sig: Int32) {
        if !dryRun { kill(pid, sig) }
    }

    private func resume(_ root: Int32, at now: Date = Date(), why: String) {
        for pid in stopped[root] ?? [] { signal(pid, SIGCONT) }
        stopped[root] = nil
        if let was = paused.removeValue(forKey: root) {
            immuneUntil[root] = now.addingTimeInterval(Guard.grace)
            events.append(Event(date: now, root: root, what: L("Continued after %@ s: %@", String(Int(now.timeIntervalSince(was.since))), why)))
        }
    }

    /// Stops whatever the session's jobs are running right now; later looks catch anything it starts afterwards.
    private func enforce(_ root: Int32) {
        for job in jobs[root] ?? [] where job.cores >= 0.1 && !(stopped[root]?.contains(job.pid) ?? false) {
            signal(job.pid, SIGSTOP)
            stopped[root, default: []].insert(job.pid)
        }
    }

    private func status() -> Status {
        Status(cpu: lastStatus.cpu, paused: paused.values.sorted { $0.since < $1.since }, exempt: exemptUntil.keys.sorted())
    }

    /// Forced continue: the session (or every paused one) runs again now and cannot be paused for a while.
    func forceContinue(_ root: Int32?) -> Status {
        let now = Date()
        for r in root.map({ [$0] }) ?? Array(paused.keys) {
            manual.remove(r)
            resume(r, at: now, why: L("forced continue"))
            immuneUntil[r] = nil
            exemptUntil[r] = now.addingTimeInterval(Guard.exemption)
        }
        persistStopped()
        lastStatus = status()
        return lastStatus
    }

    /// Manual pause: stays until the user continues it.
    func pause(_ root: Int32) -> Status {
        manual.insert(root)
        exemptUntil[root] = nil
        paused[root] = Paused(root: root, since: Date(), manual: true, hot: false)
        events.append(Event(date: Date(), root: root, what: L("Paused by you")))
        enforce(root)
        persistStopped()
        lastStatus = status()
        return lastStatus
    }

    func tick(_ input: Input) -> Status {
        let stamp = DispatchTime.now().uptimeNanoseconds
        let seconds = Double(stamp &- lastStamp) / 1e9
        // Too soon after the last look to measure anything; leave every decision as it stands.
        if lastStamp > 0, seconds < 1 { return lastStatus }
        let first = lastStamp == 0
        defer { lastStamp = stamp }
        let now = Date()
        let procs = processes()
        var children: [Int32: [Int32]] = [:]
        for (pid, info) in procs { children[info.ppid, default: []].append(pid) }

        if persist, !adopted {
            // A previous Nabd died with jobs stopped: let them go before doing anything else.
            adopted = true
            for (key, start) in UserDefaults.standard.dictionary(forKey: "guardStopped") as? [String: Double] ?? [:] {
                if let pid = Int32(key), let info = procs[pid], Double(info.start) == start { signal(pid, SIGCONT) }
            }
            UserDefaults.standard.removeObject(forKey: "guardStopped")
        }

        let cpu = systemCPU() ?? lastStatus.cpu

        func isRoot(_ pid: Int32) -> Bool {
            var current = procs[pid]?.ppid ?? 0, hops = 0
            while current > 1, hops < 32, let parent = procs[current] {
                if parent.name == "claude" { return false }
                current = parent.ppid
                hops += 1
            }
            return true
        }

        // A session's jobs are what its Bash tool shells started. MCP servers are direct children of `claude`
        // as well, but they are not shells, and freezing one would hang the agent's tool calls.
        jobs.removeAll()
        var seen = Set<Int32>()
        for (root, info) in procs where info.name == "claude" && isRoot(root) {
            var list: [(pid: Int32, cores: Double)] = []
            var queue = (children[root] ?? []).filter { Guard.shells.contains(procs[$0]?.name ?? "") }
            while let pid = queue.popLast() {
                queue.append(contentsOf: children[pid] ?? [])
                guard procs[pid]?.name != "claude", let used = cpuNanos(pid) else { continue }
                seen.insert(pid)
                let previous = lastCPU[pid]
                lastCPU[pid] = used
                if let previous, !first, used >= previous {
                    list.append((pid, Double(used - previous) / 1e9 / seconds))
                } else {
                    list.append((pid, 0))
                }
            }
            jobs[root] = list
        }
        lastCPU = lastCPU.filter { seen.contains($0.key) }
        demand = jobs.mapValues { $0.reduce(0) { $0 + ($1.cores >= 0.25 ? $1.cores : 0) } }

        // Sessions that ended take their pause with them; anything of theirs still stopped is let go.
        for root in Set(stopped.keys).union(paused.keys) where jobs[root] == nil {
            resume(root, at: now, why: L("the session ended"))
            immuneUntil[root] = nil
        }
        manual.formIntersection(jobs.keys)
        immuneUntil = immuneUntil.filter { $0.value > now }
        exemptUntil = exemptUntil.filter { $0.value > now && jobs[$0.key] != nil }

        let hot = input.thermal == .serious || input.thermal == .critical || (input.temp ?? 0) >= 92
        let cool = input.thermal != .serious && input.thermal != .critical && (input.temp ?? 0) < 85
        let limit = Double(input.limit)
        if input.limit == 0 {
            pressure = 0
            calm = 0
            for (root, info) in paused where !info.manual { resume(root, at: now, why: L("the guard was turned off")) }
        } else {
            pressure = cpu >= limit || hot ? pressure + 1 : 0
            calm = cpu < limit - Guard.margin && cool ? calm + 1 : 0

            if pressure >= Guard.sustain {
                // The heaviest session that is still running and not protected.
                let candidates = demand.filter { paused[$0.key] == nil && exemptUntil[$0.key] == nil && immuneUntil[$0.key] == nil && $0.value >= 0.5 }
                if let heaviest = candidates.max(by: { $0.value < $1.value }) {
                    paused[heaviest.key] = Paused(root: heaviest.key, since: now, manual: false, hot: cpu < limit)
                    pressure = 0
                    let reason = cpu < limit ? L("the Mac is hot") : L("CPU at %@ with the limit at %@", "\(Int(cpu.rounded()))%", "\(input.limit)%")
                    let cores = String(format: "%.1f", heaviest.value)
                    events.append(Event(date: now, root: heaviest.key, what: L("Paused: %@; it was the heaviest (%@ cores)", reason, cores)))
                }
            }

            let waiting = paused.values.filter { !$0.manual }.sorted { $0.since < $1.since }
            if let overdue = waiting.first(where: { now.timeIntervalSince($0.since) >= Guard.maximumPause }) {
                resume(overdue.root, at: now, why: L("waited the longest allowed"))
            } else if calm >= Guard.relief, let next = waiting.first(where: { now.timeIntervalSince($0.since) >= Guard.minimumPause }) {
                resume(next.root, at: now, why: L("the CPU calmed down (%@)", "\(Int(cpu.rounded()))%"))
                calm = 0
            }
        }

        for root in manual where paused[root] == nil { paused[root] = Paused(root: root, since: now, manual: true, hot: false) }
        for root in paused.keys { enforce(root) }
        for root in Array(stopped.keys) { stopped[root]?.formIntersection(seen) }
        persistStopped(procs)

        lastStatus = Status(cpu: cpu, paused: paused.values.sorted { $0.since < $1.since }, exempt: exemptUntil.keys.sorted())
        return lastStatus
    }

    private func persistStopped(_ known: [Int32: Info]? = nil) {
        guard persist else { return }
        let all = stopped.values.reduce(into: Set<Int32>()) { $0.formUnion($1) }
        guard all != saved else { return }
        saved = all
        let procs = known ?? processes()
        var record: [String: Double] = [:]
        for pid in all { if let info = procs[pid] { record[String(pid)] = Double(info.start) } }
        UserDefaults.standard.set(record, forKey: "guardStopped")
    }

    /// Lets every stopped job run again (guard switched off for good, or Nabd quitting).
    func release() {
        for pids in stopped.values { for pid in pids { signal(pid, SIGCONT) } }
        stopped.removeAll()
        paused.removeAll()
        manual.removeAll()
        if persist { UserDefaults.standard.removeObject(forKey: "guardStopped") }
    }
}

// MARK: - Processes

enum ProcessScanner {
    static let devServices: Set<String> = [
        "mysqld", "mariadbd", "postgres", "redis-server", "nginx", "httpd", "php-fpm", "php", "node", "bun", "deno",
        "python", "python3", "Python", "ruby", "java", "mongod", "memcached", "dnsmasq", "ollama", "esbuild",
        "com.docker.backend", "com.docker.virtualization", "Docker Desktop", "OrbStack", "OrbStack Helper", "colima",
        "limactl", "qemu-system-aarch64", "Virtual Machine", "Spotlight",
    ]
    static let protected: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "Claude", "Nabd", "Finder", "Dock"]
    private static let aliases = [
        "claude": "Claude Code", "com.apple.Virtualization.Virtua": "Virtual Machine",  // proc_name truncates at 31 chars
        "mds": "Spotlight", "mds_stores": "Spotlight", "mdworker_shared": "Spotlight", "mdworker": "Spotlight",
        "corespotlightd": "Spotlight", "spotlightknowledged": "Spotlight", "spotlightknowledged.updater": "Spotlight",
    ]
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "grep", "rg", "ps", "tail", "cat"]

    static func list() -> [Proc] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Axww", "-o", "pid=,ppid=,uid=,pri=,pcpu=,rss=,etime=,time=,command="]
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let myUID = getuid()
        var nameBuf = [CChar](repeating: 0, count: 128)
        var pathBuf = [CChar](repeating: 0, count: 4096)
        var out: [Proc] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard f.count == 9, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]) else { continue }
            guard pid != task.processIdentifier else { continue }
            let command = f[8].trimmingCharacters(in: .whitespaces)
            let path = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : ""
            var name = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 ? String(cString: nameBuf) : ""
            if name.isEmpty { name = (command.split(separator: " ").first.map(String.init) ?? "?").split(separator: "/").last.map(String.init) ?? "?" }
            // Footprint matches Activity Monitor; only readable for our own processes, so fall back to RSS.
            let mem = (uid == myUID ? footprint(pid) : nil) ?? (UInt64(f[5]) ?? 0) * 1024
            out.append(Proc(pid: pid, ppid: ppid, uid: uid, pri: Int(f[3].prefix { $0.isNumber }) ?? 31, cpu: Double(f[4]) ?? 0, mem: mem,
                            elapsed: clock(f[6]), cpuTime: clock(f[7]), name: name, path: path, command: command))
        }
        return out
    }

    /// Parses ps time columns: [[dd-]hh:]mm:ss[.cc]
    private static func clock(_ s: Substring) -> TimeInterval {
        let dayRest = s.split(separator: "-", maxSplits: 1)
        let days = dayRest.count == 2 ? Double(dayRest[0]) ?? 0 : 0
        let rest = dayRest.last.map { $0.split(separator: ":") } ?? []
        return rest.reduce(0) { $0 * 60 + (Double($1) ?? 0) } + days * 86400
    }

    private static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    private static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func groupName(_ p: Proc) -> String {
        var name = p.name
        if let r = p.path.range(of: ".app/"), let slash = p.path[..<r.lowerBound].lastIndex(of: "/") {
            name = String(p.path[p.path.index(after: slash)..<r.lowerBound])
        }
        return aliases[name] ?? name
    }

    static func isClaudeCode(_ p: Proc) -> Bool {
        (p.name == "claude" || p.path.contains("/claude/versions/")) && !p.command.contains("--chrome-native-host")
    }

    private static func isMCP(_ p: Proc) -> Bool {
        !isClaudeCode(p) && !p.name.hasPrefix("Claude") && !shells.contains(p.name)
            && p.command.range(of: "mcp", options: .caseInsensitive) != nil
    }

    static func analyze(_ procs: [Proc]) -> ProcReport {
        var report = ProcReport(total: procs.count)
        let myUID = getuid()
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in procs { children[p.ppid, default: []].append(p.pid) }

        func descendants(of pid: Int32) -> [Proc] {
            var result: [Proc] = [], queue = children[pid] ?? []
            while let next = queue.popLast() {
                guard let p = byPid[next] else { continue }
                result.append(p)
                queue.append(contentsOf: children[next] ?? [])
            }
            return result
        }
        func hasClaudeAncestor(_ p: Proc) -> Bool {
            var cur = p.ppid, hops = 0
            while cur > 1, hops < 32, let parent = byPid[cur] {
                if isClaudeCode(parent) { return true }
                cur = parent.ppid
                hops += 1
            }
            return false
        }

        // Groups: every process, bucketed by app bundle or executable name.
        var groups: [String: ProcGroup] = [:]
        for p in procs {
            let key = groupName(p)
            var g = groups[key] ?? ProcGroup(name: key)
            g.cpu += p.cpu
            g.mem += p.mem
            g.pids.append(p.pid)
            g.mine = g.mine && p.uid == myUID
            g.calm = g.calm && p.calm
            groups[key] = g
        }
        report.groups = Array(groups.values)

        // Claude Code sessions: each top-level `claude` process plus everything it spawned.
        var inSession = Set<Int32>()
        for root in procs where isClaudeCode(root) && !hasClaudeAncestor(root) {
            let kids = descendants(of: root.pid)
            let all = [root] + kids
            all.forEach { inSession.insert($0.pid) }
            let dir = cwd(root.pid) ?? ""
            let label = dir.contains("/scratch-workspaces/") ? L("No folder") : (dir.split(separator: "/").last.map(String.init) ?? "claude")
            let top = kids.max { $0.cpu < $1.cpu }
            let mcp = kids.filter { isMCP($0) && !(byPid[$0.ppid].map(isMCP) ?? false) }.count
            var session = ClaudeSession(id: root.pid, label: label, cwd: dir, elapsed: root.elapsed, cpu: all.reduce(0) { $0 + $1.cpu },
                                        mem: all.reduce(0) { $0 + $1.mem }, pids: all.map(\.pid), mcpCount: mcp)
            if let top, top.cpu >= 5 {
                session.topName = top.name
                session.topCPU = top.cpu
            }
            session.calm = root.calm
            report.sessions.append(session)
        }
        report.sessions.sort { ($0.cpu, Double($0.mem)) > ($1.cpu, Double($1.mem)) }

        let mcp = procs.filter(isMCP)
        report.mcpCount = mcp.filter { !(byPid[$0.ppid].map(isMCP) ?? false) }.count
        report.mcpMem = mcp.reduce(0) { $0 + $1.mem }
        report.orphanMCP = mcp.filter { $0.ppid == 1 && $0.uid == myUID && !inSession.contains($0.pid) && $0.elapsed > 120 }
        report.runaway = procs.filter {
            $0.uid == myUID && $0.cpu >= 80 && $0.elapsed >= 600 && $0.cpuTime / $0.elapsed >= 0.6
                && !isClaudeCode($0) && !protected.contains(groupName($0))
        }
        return report
    }
}

// MARK: - Sampler

final class Sampler {
    private let host = mach_host_self()
    private lazy var smc = SMC()
    private lazy var hid = HIDTemps()
    private var prevTicks: [[UInt32]] = []
    private var lastActive: [Int32: Date] = [:]
    private let started = Date()
    private let eCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    private let ncpu = ProcessInfo.processInfo.activeProcessorCount
    func sample(full: Bool, carrying previous: Snapshot? = nil) -> Snapshot {
        var s = Snapshot()
        s.ncpu = ncpu
        cpu(into: &s)
        s.mem = memory()
        s.temps = temps()
        s.power = power()
        io(into: &s)
        s.thermal = ProcessInfo.processInfo.thermalState
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        s.load = load
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 { s.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec) }
        s.procs = full ? processes() : previous?.procs
        s.advice = Advisor.advise(s)
        return s
    }

    private func cpu(into s: inout Snapshot) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(count)).map { c in (0..<states).map { UInt32(bitPattern: info[c * states + $0]) } }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return }
        let usage: [Double] = zip(ticks, prevTicks).map { now, old in
            let d = zip(now, old).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            return total > 0 ? (total - d[Int(CPU_STATE_IDLE)]) / total * 100 : 0
        }
        guard !usage.isEmpty else { return }
        s.cpuTotal = usage.reduce(0, +) / Double(usage.count)
        // Apple Silicon lists efficiency cores first.
        if eCores > 0, eCores < usage.count {
            s.cpuE = usage[..<eCores].reduce(0, +) / Double(eCores)
            s.cpuP = usage[eCores...].reduce(0, +) / Double(usage.count - eCores)
        }
    }

    private func memory() -> MemInfo {
        var m = MemInfo()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let purgeable = UInt64(stats.purgeable_count), anonymous = UInt64(stats.internal_page_count)
            m.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        m.pressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return m
    }

    private func temps() -> Temps {
        var t = Temps()
        if let smc {
            let cpu = smc.values(smc.cpuKeys), gpu = smc.values(smc.gpuKeys)
            if !cpu.isEmpty {
                t.cpu = cpu.reduce(0, +) / Double(cpu.count)
                t.cpuMax = cpu.max()
            }
            if !gpu.isEmpty { t.gpu = gpu.reduce(0, +) / Double(gpu.count) }
            t.fans = smc.fans()
        }
        let needDie = t.cpu == nil
        let hidValues = hid?.read { $0.contains("battery") || $0.contains("NAND") || (needDie && ($0.contains("tdie") || $0.contains("ACC"))) } ?? []
        let battery = hidValues.filter { $0.name.contains("battery") }.map(\.value)
        if !battery.isEmpty { t.battery = battery.reduce(0, +) / Double(battery.count) }
        t.ssd = hidValues.filter { $0.name.contains("NAND") }.map(\.value).max()
        if needDie {
            let die = hidValues.filter { $0.name.contains("tdie") || $0.name.contains("ACC") }.map(\.value)
            if !die.isEmpty {
                t.cpu = die.reduce(0, +) / Double(die.count)
                t.cpuMax = die.max()
            }
        }
        return t
    }

    // MARK: GPU, network, disk

    private var lastIOTime: TimeInterval?
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastDisk: (read: UInt64, write: UInt64)?

    private func io(into s: inout Snapshot) {
        s.gpu = gpuUsage()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastIOTime.map { now - $0 } ?? 0
        defer { lastIOTime = now }

        // Interface counters are 32-bit and wrap, so take deltas per interface with wrapping arithmetic.
        var rx = 0.0, tx = 0.0
        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0 {
            var cursor = list
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                      let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
                let name = String(cString: entry.pointee.ifa_name)
                guard !name.hasPrefix("lo") else { continue }
                let counters = (rx: data.pointee.ifi_ibytes, tx: data.pointee.ifi_obytes)
                current[name] = counters
                if let previous = lastNet[name] {
                    rx += Double(counters.rx &- previous.rx)
                    tx += Double(counters.tx &- previous.tx)
                }
            }
            freeifaddrs(list)
        }
        lastNet = current

        let disk = diskBytes()
        if elapsed > 0.2 {
            s.netIn = rx / elapsed
            s.netOut = tx / elapsed
            if let last = lastDisk, disk.read >= last.read, disk.write >= last.write {
                s.diskRead = Double(disk.read - last.read) / elapsed
                s.diskWrite = Double(disk.write - last.write) / elapsed
            }
        }
        lastDisk = disk

        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.diskTotal = values.volumeTotalCapacity.map(UInt64.init)
            s.diskFree = values.volumeAvailableCapacityForImportantUsage.map(UInt64.init)
        }
    }

    private func registryEntries(_ className: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] { out.append(dict) }
            IOObjectRelease(service)
        }
        return out
    }

    /// The graphics driver's own utilization figure (undocumented key, but what Stats and others read).
    private func gpuUsage() -> Double? {
        registryEntries("IOAccelerator").compactMap { ($0["PerformanceStatistics"] as? [String: Any])?["Device Utilization %"] as? NSNumber }
            .map(\.doubleValue).max()
    }

    private func diskBytes() -> (read: UInt64, write: UInt64) {
        registryEntries("IOBlockStorageDriver").reduce((UInt64(0), UInt64(0))) { total, entry in
            guard let stats = entry["Statistics"] as? [String: Any] else { return total }
            return (total.0 + ((stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0), total.1 + ((stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0))
        }
    }

    private func power() -> PowerInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }  // a Mac without a battery
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        func number(_ key: String) -> NSNumber? { value(key) as? NSNumber }

        var p = PowerInfo()
        p.plugged = (value("ExternalConnected") as? Bool) ?? false
        p.charging = (value("IsCharging") as? Bool) ?? false
        p.percent = number("CurrentCapacity")?.intValue
        if let minutes = number("TimeRemaining")?.intValue, minutes > 0, minutes < 65535 { p.minutesLeft = minutes }
        p.cycles = number("CycleCount")?.intValue
        if let data = value("BatteryData") as? [String: Any], let full = (data["FullChargeCapacity"] as? NSNumber)?.doubleValue,
           let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue, design > 0 {
            p.health = min(100, full / design * 100)
        }
        if p.plugged, let adapter = value("AdapterDetails") as? [String: Any] {
            p.adapterWatts = (adapter["Watts"] as? NSNumber)?.doubleValue
            p.adapterName = adapter["Name"] as? String
        }
        // Battery side: volts × amps, signed (negative while the battery is feeding the Mac).
        if let mV = number("Voltage")?.doubleValue, let mA = number("InstantAmperage")?.int64Value {
            p.battery = mV * Double(mA) / 1_000_000
        }
        if let telemetry = value("PowerTelemetryData") as? [String: Any] {
            func watts(_ key: String) -> Double? { (telemetry[key] as? NSNumber).map { $0.doubleValue / 1000 } }
            p.system = watts("SystemLoad").flatMap { $0 > 0 ? $0 : nil }
            if p.plugged {
                p.input = watts("SystemPowerIn")
                p.loss = watts("AdapterEfficiencyLoss")
            }
        }
        if p.system == nil, !p.plugged, let b = p.battery, b < 0 { p.system = -b }
        return p
    }

    private func processes() -> ProcReport {
        var report = ProcessScanner.analyze(ProcessScanner.list())
        let now = Date()
        for i in report.sessions.indices {
            let id = report.sessions[i].id
            if report.sessions[i].cpu >= 2 { lastActive[id] = now }
            let quiet = now.timeIntervalSince(lastActive[id] ?? started)
            report.sessions[i].quietFor = quiet
            // Never seen busy since we started watching counts as idle at once; otherwise wait for ten quiet minutes.
            report.sessions[i].idle = report.sessions[i].cpu < 1 && report.sessions[i].elapsed > 7200 && (lastActive[id] == nil || quiet > 600)
        }
        let alive = Set(report.sessions.map(\.id))
        lastActive = lastActive.filter { alive.contains($0.key) }
        return report
    }
}

// MARK: - Advisor

enum Advisor {
    static func advise(_ s: Snapshot) -> [Advice] {
        var out: [Advice] = []
        let groups = s.procs?.groups ?? []
        let sep = L(", ")
        let topCPU = groups.sorted { $0.cpu > $1.cpu }.prefix(3).filter { $0.cpu >= 10 }
            .map { "\(ltr($0.name)) \(ltr(fmtPct($0.cpu)))" }.joined(separator: sep)
        let topMem = groups.sorted { $0.mem > $1.mem }.prefix(3).map { "\(ltr($0.name)) \(ltr(fmtBytes($0.mem)))" }.joined(separator: sep)

        if s.thermal == .serious || s.thermal == .critical {
            out.append(Advice(id: "thermal", level: .crit, title: L("The Mac is hot and macOS is slowing it down"),
                              detail: L("Thermal state: %@. Pause or calm the heaviest work: %@.", s.thermal.localized, topCPU)))
        } else if let t = s.temps.cpu, t >= 80 {
            out.append(Advice(id: "temp", level: t >= 95 ? .crit : .warn, title: L("CPU temperature is high (%@)", ltr(String(format: "%.0f°", t))),
                              detail: L("Heaviest now: %@. Pause the heaviest session from the panel, or let the guard do it at the limit.", topCPU)))
        } else if let fan = s.temps.fans.max(by: { $0.fraction < $1.fraction }), fan.fraction >= 0.9 {
            out.append(Advice(id: "fans", level: .warn, title: L("Fans at full speed (%@)", ltr(String(format: "%.0f rpm", fan.rpm))),
                              detail: L("Sustained load makes heat and the fans make up for it. Pausing the heaviest session lowers heat and noise.")))
        }

        let ratio = s.load[0] / Double(max(1, s.ncpu))
        if ratio >= 2, s.cpuTotal >= 90 {
            out.append(Advice(id: "load", level: ratio >= 4 ? .crit : .warn, title: L("The CPU is overloaded (%@)", ltr(String(format: "%.1f×", ratio))),
                              detail: L("Load average %@ on %@ cores: work is waiting its turn. Heaviest: %@.",
                                        ltr(String(format: "%.0f", s.load[0])), String(s.ncpu), topCPU.isEmpty ? "—" : topCPU)))
        }

        if s.mem.pressure >= 2 {
            out.append(Advice(id: "pressure", level: s.mem.pressure >= 4 ? .crit : .warn, title: L("Memory pressure"),
                              detail: L("macOS is compressing memory and writing it to disk. Largest: %@.", topMem)))
        }
        if s.mem.total > 0, Double(s.mem.swapUsed) >= Double(s.mem.total) * 0.25 {
            let restart = s.uptime > 5 * 86400 ? " " + L("The Mac has been up for %@; a restart clears swap.", fmtDuration(s.uptime)) : ""
            out.append(Advice(id: "swap", level: .warn, title: L("Swap is high (%@)", ltr(fmtBytes(s.mem.swapUsed))),
                              detail: L("The disk is standing in for memory, which slows switching between apps. Largest: %@.", topMem) + restart))
        }
        if let total = s.diskTotal, let free = s.diskFree, total > 0, Double(free) < Double(total) * 0.08 {
            out.append(Advice(id: "disk", level: .warn, title: L("The disk is almost full (%@ free)", ltr(fmtDisk(free))),
                              detail: L("macOS needs free space for swap and updates. Empty the Trash, or clear caches such as node_modules and Docker images.")))
        }

        if let power = s.power, power.plugged, let battery = power.battery, battery < -2 {
            out.append(Advice(id: "charger", level: .warn, title: L("The battery drains while plugged in"),
                              detail: L("The Mac draws %@ more than the charger (%@) supplies. Use a stronger charger or lighten the load.",
                                        ltr(String(format: "%.0f W", -battery)), ltr(String(format: "%.0fW", power.adapterWatts ?? 0)))))
        }

        guard let p = s.procs else { return sorted(out) }

        for proc in p.runaway.prefix(2) {
            out.append(Advice(id: "runaway-\(proc.pid)", level: .warn, title: L("Probably stuck: %@", ltr(proc.name)),
                              detail: L("Using %@ for %@ (PID %@). If it isn't intended work, quit it.", ltr(fmtPct(proc.cpu)), fmtDuration(proc.elapsed), String(proc.pid)),
                              killPids: [proc.pid]))
        }
        if !p.orphanMCP.isEmpty {
            let mem = p.orphanMCP.reduce(UInt64(0)) { $0 + $1.mem }
            out.append(Advice(id: "orphan-mcp", level: .warn, title: L("Orphaned MCP servers (%@)", String(p.orphanMCP.count)),
                              detail: L("Still running after their session closed, holding %@.", ltr(fmtBytes(mem))), killPids: p.orphanMCP.map(\.pid)))
        }
        let idle = p.sessions.filter(\.idle)
        if !idle.isEmpty {
            let mem = idle.reduce(UInt64(0)) { $0 + $1.mem }
            let names = idle.prefix(3).map { "\(ltr($0.label)) (\(fmtDuration($0.elapsed)))" }.joined(separator: sep)
            out.append(Advice(id: "idle-sessions", level: .ok,
                              title: idle.count == 1 ? L("1 idle Claude Code session") : L("%@ idle Claude Code sessions", String(idle.count)),
                              detail: L("Holding %@, MCP servers: %@ — %@. Archive them in the Claude app or quit them with ✕.",
                                        ltr(fmtBytes(mem)), String(idle.reduce(0) { $0 + $1.mcpCount }), names)))
        }
        if p.mcpCount >= 8 {
            out.append(Advice(id: "mcp", level: .ok, title: L("%@ MCP servers running (%@)", String(p.mcpCount), ltr(fmtBytes(p.mcpMem))),
                              detail: L("Every session runs its own copy of each server. Turn off the ones you don't use to make sessions lighter.")))
        }
        if let desktop = p.desktop, desktop.mem >= 3 * 1_073_741_824 {
            out.append(Advice(id: "desktop", level: .ok, title: L("The Claude app itself is heavy (%@)", ltr(fmtBytes(desktop.mem))),
                              detail: L("Long conversations weigh on the app. Start new sessions for new tasks, or restart the app.")))
        }
        if let kernel = groups.first(where: { $0.name == "kernel_task" }), kernel.cpu >= 60 {
            out.append(Advice(id: "kernel", level: .ok, title: L("kernel_task is high (%@)", ltr(fmtPct(kernel.cpu))),
                              detail: L("macOS holds the CPU on purpose to cool the Mac down. A sign of heat, not a fault.")))
        }
        if let spotlight = groups.first(where: { $0.name == "Spotlight" }), spotlight.cpu >= 50 {
            out.append(Advice(id: "spotlight", level: .ok, title: L("Spotlight is indexing"),
                              detail: L("Usually temporary. If it keeps happening, exclude project folders in System Settings → Spotlight.")))
        }
        return sorted(out)
    }

    private static func sorted(_ a: [Advice]) -> [Advice] {
        a.enumerated().sorted { ($0.element.level.rawValue, -$0.offset) > ($1.element.level.rawValue, -$1.offset) }.map(\.element)
    }
}

// MARK: - CLI

enum CLI {
    static func snapshot() -> Snapshot {
        let sampler = Sampler()
        _ = sampler.sample(full: false)
        usleep(500_000)
        return sampler.sample(full: true)
    }

    static func line(_ s: Snapshot, compact: Bool = false) -> String {
        var parts: [String] = []
        if let t = s.temps.cpu { parts.append(String(format: "%.0f°", t)) }
        if !compact || parts.isEmpty { parts += ["CPU " + fmtPct(s.cpuTotal), "RAM " + fmtPct(s.mem.percent)] }
        if !compact, let w = s.power?.draw { parts.append(String(format: "%.0fW", w)) }
        return parts.joined(separator: "  ")
    }

    private static let tty = isatty(STDOUT_FILENO) == 1
    private static func paint(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    private static func paint(_ s: String, _ level: Level) -> String { level == .ok ? s : paint(s, level == .crit ? "1;31" : "33") }
    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
    private static func lpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
    private static func deg(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "n/a" }
    /// Terminals and JSON consumers do not need the bidi isolates the GUI text carries.
    private static func plain(_ s: String) -> String { s.filter { !"\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}".contains($0) } }

    static func status() {
        let s = snapshot()
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        print(paint("Nabd · \(chip) · up \(fmtDuration(s.uptime, localized: false))", "1"))
        var temp = "TEMP  " + paint("CPU \(deg(s.temps.cpu))", s.tempLevel) + " (max \(deg(s.temps.cpuMax)))  GPU \(deg(s.temps.gpu))  SSD \(deg(s.temps.ssd))  BAT \(deg(s.temps.battery))"
        temp += "  thermal: \(s.thermal.english)"
        print(temp)
        if !s.temps.fans.isEmpty {
            print("FANS  " + s.temps.fans.map { String(format: "%.0f rpm (%.0f%%)", $0.rpm, $0.fraction * 100) }.joined(separator: "  "))
        }
        var cpu = "CPU   " + paint(fmtPct(s.cpuTotal), s.cpuLevel)
        if let p = s.cpuP, let e = s.cpuE { cpu += "  (P \(fmtPct(p)) · E \(fmtPct(e)))" }
        print(cpu + String(format: "  load %.1f %.1f %.1f on %d cores", s.load[0], s.load[1], s.load[2], s.ncpu))
        let pressure = [1: "normal", 2: "warning", 4: "critical"][s.mem.pressure] ?? "?"
        print("RAM   " + paint("\(fmtBytes(s.mem.used)) / \(fmtBytes(s.mem.total)) (\(fmtPct(s.mem.percent)))", s.memLevel)
            + "  app \(fmtBytes(s.mem.app)) · wired \(fmtBytes(s.mem.wired)) · compressed \(fmtBytes(s.mem.compressed))")
        print("      swap \(fmtBytes(s.mem.swapUsed)) / \(fmtBytes(s.mem.swapTotal))  pressure: \(pressure)")
        var io: [String] = []
        if let g = s.gpu { io.append("GPU \(fmtPct(g))") }
        if let rx = s.netIn, let tx = s.netOut { io.append("net ↓\(fmtRate(rx)) ↑\(fmtRate(tx))") }
        if let r = s.diskRead, let w = s.diskWrite { io.append("disk read \(fmtRate(r)) write \(fmtRate(w))") }
        if let free = s.diskFree, let total = s.diskTotal { io.append("\(fmtDisk(free)) free of \(fmtDisk(total))") }
        if !io.isEmpty { print("I/O   " + io.joined(separator: " · ")) }
        if let p = s.power {
            func w(_ v: Double?) -> String { v.map { String(format: "%.1f W", $0) } ?? "n/a" }
            if p.plugged {
                print("POWER " + paint("\(w(p.wall)) from the wall", "1") + " · charger \(p.adapterWatts.map { String(format: "%.0fW", $0) } ?? "?")"
                    + " · Mac \(w(p.system)) · battery \(p.battery.map { String(format: "%+.1f W", $0) } ?? "n/a") · charger loss \(w(p.loss))"
                    + " · battery \(p.percent.map { "\($0)%" } ?? "?")\(p.charging ? " charging" : "")"
                    + (p.health.map { String(format: " · health %.0f%%", $0) } ?? "") + (p.cycles.map { " · \($0) cycles" } ?? ""))
            } else {
                print("POWER " + paint("\(w(p.draw)) from the battery", "1") + " · battery \(p.percent.map { "\($0)%" } ?? "?")"
                    + (p.minutesLeft.map { " · \(fmtDuration(TimeInterval($0 * 60), localized: false)) left" } ?? ""))
            }
        }

        guard let p = s.procs else { return }
        print("\n" + paint("CLAUDE CODE  (\(p.sessions.count) sessions · \(p.mcpCount) MCP servers · \(fmtBytes(p.mcpMem)))", "1"))
        for x in p.sessions {
            let label = x.cwd.contains("/scratch-workspaces/") ? "(no folder)" : x.label
            var row = "  " + pad(label, 28) + lpad(fmtDuration(x.elapsed, localized: false), 8) + lpad(fmtPct(x.cpu), 7) + lpad(fmtBytes(x.mem), 9) + "  mcp \(x.mcpCount)"
            if let top = x.topName { row += "  ▸ \(top) \(fmtPct(x.topCPU))" }
            if x.idle { row += "  idle" }
            if x.calm { row += "  calm" }
            print(row + "  [pid \(x.id)]")
        }
        if let d = p.desktop { print("  " + pad("Claude desktop app", 28) + lpad("", 8) + lpad(fmtPct(d.cpu), 7) + lpad(fmtBytes(d.mem), 9) + "  \(d.pids.count) procs") }

        func table(_ title: String, _ rows: [ProcGroup]) {
            print("\n" + paint(title, "1"))
            for g in rows {
                print("  " + pad(g.name + (g.pids.count > 1 ? " ×\(g.pids.count)" : ""), 36) + lpad(fmtPct(g.cpu), 7) + lpad(fmtBytes(g.mem), 9) + (g.calm ? "  calm" : ""))
            }
        }
        table("TOP CPU  (100% = one core)", Array(p.groups.sorted { $0.cpu > $1.cpu }.prefix(6)))
        table("TOP MEMORY", Array(p.groups.sorted { $0.mem > $1.mem }.prefix(6)))
        let services = p.groups.filter { ProcessScanner.devServices.contains($0.name) }.sorted { ($0.cpu, Double($0.mem)) > ($1.cpu, Double($1.mem)) }
        if !services.isEmpty { table("BACKGROUND DEV SERVICES", Array(services.prefix(8))) }
        printAdvice(s)
    }

    static func printAdvice(_ s: Snapshot) {
        print("\n" + paint("ADVICE", "1"))
        if s.advice.isEmpty { print("  ✓ " + L("All good")) }
        for a in s.advice {
            let mark = a.level == .crit ? paint("‼", "1;31") : (a.level == .warn ? paint("!", "33") : "·")
            print("  \(mark) \(plain(a.title))\n      \(plain(a.detail))")
        }
    }

    static func json() {
        let s = snapshot()
        var root: [String: Any] = [
            "cpu": ["total": s.cpuTotal, "performance": s.cpuP as Any, "efficiency": s.cpuE as Any, "load": s.load, "cores": s.ncpu],
            "memory": ["total": s.mem.total, "used": s.mem.used, "percent": s.mem.percent, "app": s.mem.app, "wired": s.mem.wired,
                       "compressed": s.mem.compressed, "cached": s.mem.cached, "swapUsed": s.mem.swapUsed, "swapTotal": s.mem.swapTotal,
                       "pressure": s.mem.pressure],
            "io": ["gpuPercent": s.gpu as Any, "networkInBytesPerSec": s.netIn as Any, "networkOutBytesPerSec": s.netOut as Any,
                   "diskReadBytesPerSec": s.diskRead as Any, "diskWriteBytesPerSec": s.diskWrite as Any,
                   "diskFree": s.diskFree as Any, "diskTotal": s.diskTotal as Any] as [String: Any],
            "temperature": ["cpu": s.temps.cpu as Any, "cpuMax": s.temps.cpuMax as Any, "gpu": s.temps.gpu as Any, "ssd": s.temps.ssd as Any,
                            "battery": s.temps.battery as Any, "thermalState": s.thermal.english,
                            "fans": s.temps.fans.map { ["rpm": $0.rpm, "min": $0.min, "max": $0.max] }],
            "uptime": s.uptime,
            "power": s.power.map { p in
                ["plugged": p.plugged, "charging": p.charging, "wallWatts": p.wall as Any, "chargerOutputWatts": p.input as Any,
                 "macWatts": p.system as Any, "batteryWatts": p.battery as Any, "chargerLossWatts": p.loss as Any,
                 "chargerRatingWatts": p.adapterWatts as Any, "batteryPercent": p.percent as Any,
                 "batteryHealthPercent": p.health as Any, "batteryCycles": p.cycles as Any] as [String: Any]
            } as Any,
            "advice": s.advice.map { ["level": ["info", "warn", "crit"][$0.level.rawValue], "title": plain($0.title), "detail": plain($0.detail), "pids": $0.killPids] },
        ]
        if let p = s.procs {
            root["processCount"] = p.total
            root["claudeCode"] = [
                "mcpServers": p.mcpCount, "mcpMemory": p.mcpMem,
                "sessions": p.sessions.map {
                    ["pid": $0.id, "cwd": $0.cwd, "elapsed": $0.elapsed, "cpu": $0.cpu, "memory": $0.mem, "processes": $0.pids.count,
                     "mcpServers": $0.mcpCount, "idle": $0.idle, "calm": $0.calm, "heaviestChild": $0.topName as Any] as [String: Any]
                },
            ] as [String: Any]
            let rows = { (g: ProcGroup) -> [String: Any] in ["name": g.name, "cpu": g.cpu, "memory": g.mem, "processes": g.pids.count] }
            root["topCPU"] = p.groups.sorted { $0.cpu > $1.cpu }.prefix(10).map(rows)
            root["topMemory"] = p.groups.sorted { $0.mem > $1.mem }.prefix(10).map(rows)
        }
        func clean(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.mapValues(clean) }
            if let a = v as? [Any] { return a.map(clean) }
            if case Optional<Any>.none = v { return NSNull() }
            if let d = v as? Double { return (d * 10).rounded() / 10 }
            return v
        }
        let data = (try? JSONSerialization.data(withJSONObject: clean(root), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    static func sensors() {
        guard let smc = SMC() else { return print("SMC unavailable") }
        for (title, keys) in [("CPU", smc.cpuKeys), ("GPU", smc.gpuKeys)] {
            print(title + ": " + keys.map { "\(SMC.name($0))=\(smc.read($0).map { String(format: "%.1f", $0) } ?? "?")" }.joined(separator: " "))
        }
        print("Fans: " + smc.fans().map { String(format: "%.0f rpm [%.0f–%.0f]", $0.rpm, $0.min, $0.max) }.joined(separator: ", "))
        for sensor in HIDTemps()?.read({ _ in true }) ?? [] { print(String(format: "HID %@ = %.1f", sensor.name, sensor.value)) }
    }

    /// `calm <pid|name>…` moves processes (and what they spawned) to the background band; `uncalm` restores them.
    static func calm(_ targets: [String], on: Bool) {
        let procs = ProcessScanner.list()
        var pids = Set<Int32>()
        for target in targets {
            let roots = Int32(target).map { [$0] } ?? procs.filter {
                $0.name.caseInsensitiveCompare(target) == .orderedSame || ProcessScanner.groupName($0).caseInsensitiveCompare(target) == .orderedSame
            }.map(\.pid)
            var queue = roots
            while let pid = queue.popLast() {
                guard pids.insert(pid).inserted else { continue }
                queue += procs.filter { $0.ppid == pid }.map(\.pid)
            }
        }
        // Never hold the agent itself back: a calmed `claude` crawls and everything it starts inherits the band.
        let agents = Set(procs.filter { on && pids.contains($0.pid) && ProcessScanner.isClaudeCode($0) }.map(\.pid))
        if !agents.isEmpty { print("skipping \(agents.count) claude process(es); calming only what they started") }
        pids.subtract(agents)
        Priority.set(Array(pids), background: on)
        let done = ProcessScanner.list().filter { pids.contains($0.pid) && $0.calm == on }
        print("\(on ? "calmed" : "restored") \(done.count) of \(pids.count) processes")
    }

    /// Shows what the guard sees right now, without touching anything.
    static func guardReport(limit: Int) {
        let g = Guard()
        g.dryRun = true
        _ = g.tick(Guard.Input(limit: limit))
        sleep(2)
        let status = g.tick(Guard.Input(limit: limit))
        let sessions = ProcessScanner.analyze(ProcessScanner.list()).sessions
        let ranked = g.demand.sorted { $0.value > $1.value }
        print(String(format: "System CPU %.0f%% · limit %d%% · the guard pauses the heaviest session after ~12 s at the limit (dry run)", status.cpu, limit))
        for (i, entry) in ranked.enumerated() {
            let session = sessions.first { $0.id == entry.key }
            let label = session.map { $0.cwd.contains("/scratch-workspaces/") ? "(no folder)" : $0.label } ?? "?"
            print("  " + lpad(String(entry.key), 6) + "  " + pad(label, 30) + lpad(String(format: "%.0f%%", entry.value * 100), 6)
                + (i == 0 && entry.value >= 0.5 ? "  ← heaviest: first to be paused" : ""))
        }
    }

    /// `nabd login on|off` registers the app to start with the Mac; with no argument it only reports.
    static func login(_ want: String?) {
        do {
            if want == "on" { try SMAppService.mainApp.register() }
            if want == "off" { try SMAppService.mainApp.unregister() }
        } catch {
            print("could not change it: \(error.localizedDescription)")
        }
        switch SMAppService.mainApp.status {
        case .enabled: print("start at login: on")
        case .requiresApproval: print("start at login: waiting for approval in System Settings → General → Login Items")
        case .notRegistered: print("start at login: off")
        case .notFound: print("start at login: unavailable (app not found by the system)")
        @unknown default: print("start at login: unknown")
        }
    }

    /// What the guard did lately and why.
    static func guardLog() {
        let log = CFPreferencesCopyAppValue("guardLog" as CFString, "local.nabd.monitor" as CFString) as? [String] ?? []
        print(log.isEmpty ? "the guard has not paused anything yet" : log.suffix(25).joined(separator: "\n"))
    }

    /// Forced continue from the terminal. With no Nabd running it simply wakes anything left stopped.
    static func forceContinue() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "local.nabd.monitor").isEmpty {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.nabd.monitor.continue"), object: nil, userInfo: nil, deliverImmediately: true)
            usleep(300_000)
            print("asked Nabd to continue every paused session; they are exempt from pausing for 15 minutes")
        } else {
            let pids = ProcessScanner.analyze(ProcessScanner.list()).sessions.flatMap { $0.pids.dropFirst() }
            pids.forEach { kill($0, SIGCONT) }
            print("Nabd is not running; sent a continue signal to \(pids.count) session job processes")
        }
    }

    static func usage() {
        print("""
        Nabd — Mac temperature, CPU, memory and power monitor

          nabd                 menu bar app (same as: open Nabd.app)
          nabd open            menu bar app with the panel already open
          nabd window          menu bar app with the panel in a window
          nabd status          full report in the terminal
          nabd doctor          advice only
          nabd line            one line: 59°  CPU 42%  RAM 71%
          nabd json            everything as JSON
          nabd sensors         raw temperature sensors and fans
          nabd guard [limit]   what the guard sees: system CPU and each session's load (dry run)
          nabd continue        forced continue: resume every session the guard paused
          nabd log             what the guard paused or continued lately, and why
          nabd login [on|off]  start with the Mac
          nabd calm <pid|name> move a process tree to efficiency cores (cooler, slower)
          nabd uncalm <pid|name>
        """)
    }
}

// MARK: - GUI model

final class Model: ObservableObject {
    @Published var snap = Snapshot()
    // What the menu bar shows.
    @Published var barTemp = Model.flag("bar.temp", true) { didSet { Model.save("bar.temp", barTemp); onUpdate?() } }
    @Published var barCPU = Model.flag("bar.cpu", true) { didSet { Model.save("bar.cpu", barCPU); onUpdate?() } }
    @Published var barGPU = Model.flag("bar.gpu", false) { didSet { Model.save("bar.gpu", barGPU); onUpdate?() } }
    @Published var barRAM = Model.flag("bar.ram", true) { didSet { Model.save("bar.ram", barRAM); onUpdate?() } }
    @Published var barNet = Model.flag("bar.net", false) { didSet { Model.save("bar.net", barNet); onUpdate?() } }
    @Published var barPower = Model.flag("bar.power", true) { didSet { Model.save("bar.power", barPower); onUpdate?() } }
    @Published var checkUpdates = Model.flag("checkUpdates", true) {
        didSet {
            Model.save("checkUpdates", checkUpdates)
            if checkUpdates { checkForUpdates() } else { update = nil }
        }
    }
    /// A newer release on GitHub, if there is one.
    @Published var update: (version: String, url: URL)?
    /// The last 30 minutes, for the History tab.
    @Published var history: [HistoryPoint] = []

    static func flag(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
    private static func save(_ key: String, _ value: Bool) { UserDefaults.standard.set(value, forKey: key) }

    /// What goes after the icon in the menu bar.
    var barText: String {
        let s = snap
        var parts: [String] = []
        if barTemp, let t = s.temps.cpu { parts.append(String(format: "%.0f°", t)) }
        if barCPU { parts.append("CPU " + fmtPct(s.cpuTotal)) }
        if barGPU, let g = s.gpu { parts.append("GPU " + fmtPct(g)) }
        if barRAM { parts.append("RAM " + fmtPct(s.mem.percent)) }
        if barNet, let rx = s.netIn, let tx = s.netOut { parts.append("↓" + fmtRate(rx, short: true) + " ↑" + fmtRate(tx, short: true)) }
        if barPower, let w = s.power?.draw { parts.append(String(format: "%.0fW", w)) }
        return parts.joined(separator: "  ")
    }

    /// Asks GitHub for the latest release once a day; nothing is sent besides the request itself.
    func checkForUpdates() {
        guard checkUpdates, let api = URL(string: "https://api.github.com/repos/amjadArqan/nabd/releases/latest") else { return }
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async { self.update = (latest, page) }
        }.resume()
    }
    @Published var loginItem = false
    var onUpdate: (() -> Void)?
    var popoverOpen = false {
        didSet {
            schedule()
            if popoverOpen {
                loginItem = SMAppService.mainApp.status == .enabled
                refresh(full: true)
            }
        }
    }

    private let sampler = Sampler()
    // Not .utility: on a saturated machine low-QoS work is starved exactly when the readings matter most.
    private let queue = DispatchQueue(label: "nabd.sampler", qos: .userInitiated)
    private var timer: Timer?
    private var ticks = 0
    private var busy = false
    private var pendingFull = false

    /// System CPU % at which the guard pauses the heaviest session (0 = off).
    let limitChoices = [80, 90, 95]
    @Published var guardLimit: Int = UserDefaults.standard.object(forKey: "guardLimit") as? Int ?? 90 {
        didSet {
            UserDefaults.standard.set(guardLimit, forKey: "guardLimit")
            pushGuardInput(runNow: true)
        }
    }
    @Published var guardStatus = Guard.Status()
    /// Called on the main thread for each session the guard has just paused on its own.
    var onPause: ((Guard.Paused, String, Double) -> Void)?
    /// Opens the panel as a regular window.
    var onOpenWindow: (() -> Void)?
    private let guardian = Guard()
    private let guardQueue = DispatchQueue(label: "nabd.guard", qos: .userInitiated)
    private var guardTimer: DispatchSourceTimer?
    private let guardLock = NSLock()
    private var guardInput = Guard.Input()
    private var announced: [Int32: Date] = [:]

    func start() {
        loginItem = SMAppService.mainApp.status == .enabled
        checkForUpdates()
        let daily = Timer(timeInterval: 86400, repeats: true) { [weak self] _ in self?.checkForUpdates() }
        RunLoop.main.add(daily, forMode: .common)
        refresh(full: true)
        schedule()
        guardian.persist = true
        pushGuardInput(runNow: false)
        let timer = DispatchSource.makeTimerSource(queue: guardQueue)
        timer.schedule(deadline: .now() + 1, repeating: Guard.interval, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.runGuard() }
        timer.resume()
        guardTimer = timer
    }

    /// Main thread: hands the guard the current settings and readings.
    private func pushGuardInput(runNow: Bool) {
        let input = Guard.Input(limit: guardLimit, temp: snap.temps.cpu, thermal: snap.thermal)
        guardLock.lock()
        guardInput = input
        guardLock.unlock()
        if runNow { guardQueue.async { self.runGuard() } }
    }

    /// Guard queue.
    private func runGuard() {
        guardLock.lock()
        let input = guardInput
        guardLock.unlock()
        publish(guardian.tick(input), guardian.drainEvents())
    }

    /// Any thread: shows the guard's state and announces sessions it has just paused.
    private func publish(_ status: Guard.Status, _ events: [Guard.Event]) {
        DispatchQueue.main.async {
            if !events.isEmpty {
                let stamp = DateFormatter()
                stamp.dateFormat = "HH:mm:ss"
                var log = UserDefaults.standard.stringArray(forKey: "guardLog") ?? []
                log += events.map { "\(stamp.string(from: $0.date))  «\(self.sessionLabel($0.root))» [\($0.root)]  \($0.what)" }
                UserDefaults.standard.set(Array(log.suffix(60)), forKey: "guardLog")
            }
            let before = Set(self.guardStatus.paused.map(\.root))
            let fresh = status.paused.filter { !$0.manual && !before.contains($0.root) }
            if status != self.guardStatus {
                self.guardStatus = status
                self.onUpdate?()
            }
            guard !fresh.isEmpty else { return }
            self.refresh(full: true)
            let now = Date()
            for item in fresh where now.timeIntervalSince(self.announced[item.root] ?? .distantPast) > 300 {
                self.announced[item.root] = now
                self.onPause?(item, self.sessionLabel(item.root), status.cpu)
            }
        }
    }

    func sessionLabel(_ root: Int32) -> String {
        snap.procs?.sessions.first { $0.id == root }?.label ?? "Claude Code"
    }

    /// Forced continue for one session, or for all of them with nil.
    func forceContinue(_ root: Int32?) {
        guardQueue.async { self.publish(self.guardian.forceContinue(root), self.guardian.drainEvents()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh(full: true) }
    }

    func pause(_ root: Int32) {
        guardQueue.async { self.publish(self.guardian.pause(root), self.guardian.drainEvents()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh(full: true) }
    }

    /// Nothing may stay stopped after Nabd is gone.
    func shutdown() {
        guardTimer?.cancel()
        guardQueue.sync { guardian.release() }
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: popoverOpen ? 2 : 4, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        ticks += 1
        // The process scan is the expensive part: run it live while the popover is open, rarely otherwise.
        refresh(full: popoverOpen || ticks % 8 == 0)
    }

    func refresh(full: Bool) {
        guard !busy else {
            pendingFull = pendingFull || full
            return
        }
        busy = true
        let previous = snap
        queue.async {
            let s = self.sampler.sample(full: full, carrying: previous)
            DispatchQueue.main.async {
                self.busy = false
                self.apply(s)
                if self.pendingFull {
                    self.pendingFull = false
                    self.refresh(full: true)
                }
            }
        }
    }

    func apply(_ s: Snapshot) {
        snap = s
        pushGuardInput(runNow: false)
        trackEnergy(s.power?.draw)
        let now = Date()
        history.append(HistoryPoint(time: now, cpu: s.cpuTotal, gpu: s.gpu, temp: s.temps.cpu, mem: s.mem.percent,
                                    power: s.power?.draw, netIn: s.netIn, netOut: s.netOut))
        if let first = history.first, now.timeIntervalSince(first.time) > 1800 { history.removeAll { now.timeIntervalSince($0.time) > 1800 } }
        onUpdate?()
    }

    /// Highest draw since Nabd started, and energy used today while Nabd was running (Wh).
    @Published var powerPeak = 0.0
    @Published var energyToday = UserDefaults.standard.double(forKey: "energyToday")
    private var lastPowerAt: Date?
    private var energySavedAt = Date()

    private func trackEnergy(_ watts: Double?) {
        let now = Date()
        defer { lastPowerAt = watts == nil ? nil : now }
        guard let watts else { return }
        powerPeak = max(powerPeak, watts)
        let day = UserDefaults.standard.object(forKey: "energyDay") as? Date ?? now
        if !Calendar.current.isDate(day, inSameDayAs: now) {
            energyToday = 0
            UserDefaults.standard.set(now, forKey: "energyDay")
        } else if UserDefaults.standard.object(forKey: "energyDay") == nil {
            UserDefaults.standard.set(now, forKey: "energyDay")
        }
        // Long gaps (sleep, Nabd closed) are not counted rather than guessed.
        if let last = lastPowerAt, now.timeIntervalSince(last) < 30 { energyToday += watts * now.timeIntervalSince(last) / 3600 }
        if now.timeIntervalSince(energySavedAt) > 60 {
            UserDefaults.standard.set(energyToday, forKey: "energyToday")
            energySavedAt = now
        }
    }

    /// Blocking fill used for the offscreen snapshot render.
    func fillSynchronously(samples: Int) {
        for i in 0..<samples {
            apply(sampler.sample(full: i == samples - 1, carrying: snap))
            usleep(300_000)
        }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Nabd: login item change failed: \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }

    func toggleCalm(_ pids: [Int32], isCalm: Bool) {
        Priority.set(pids, background: !isCalm)
        refresh(full: true)
    }

    func confirmKill(_ what: String, detail: String, pids: [Int32]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Quit %@?", what)
        alert.informativeText = detail
        alert.addButton(withTitle: L("Quit"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let me = getpid()
        for pid in pids.reversed() where pid > 1 && pid != me { kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh(full: true) }
    }
}

// MARK: - Views

extension Level {
    var color: Color {
        switch self {
        case .ok: return .primary
        case .warn: return .orange
        case .crit: return .red
        }
    }
}

// MARK: Building blocks

/// One metric as a ring, the way macOS widgets show capacity.
struct Ring: View {
    let caption: String
    let value: String
    let fraction: Double
    let level: Level
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(level == .ok ? Color.accentColor : level.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .foregroundStyle(level == .ok ? Color.primary : level.color)
                    .contentTransition(.numericText())
            }
            .frame(width: 54, height: 54)
            Text(caption).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caption) \(value), \(detail)")
    }
}

/// A grouped surface, like the boxes in System Settings.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// List rows light up under the pointer, as in native lists.
struct HoverRow: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Small icon button with a comfortable hit area, a tooltip and a spoken name.
struct IconButton: View {
    let symbol: String
    let label: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A small line chart for the History tab: one or two series over the last 30 minutes.
struct MiniChart: View {
    let title: String
    let current: String
    let points: [HistoryPoint]
    let series: [(name: String, color: Color, value: (HistoryPoint) -> Double?)]
    var domain: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(current).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
            Chart {
                ForEach(series.indices, id: \.self) { i in
                    ForEach(points) { point in
                        if let v = series[i].value(point) {
                            LineMark(x: .value("Time", point.time), y: .value(series[i].name, v), series: .value("Series", series[i].name))
                                .foregroundStyle(series[i].color)
                                .interpolationMethod(.monotone)
                        }
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisGridLine(); AxisValueLabel() } }
            .modifier(OptionalDomain(domain: domain))
            .frame(height: 52)
            .accessibilityLabel("\(title) \(current)")
        }
    }
}

private struct OptionalDomain: ViewModifier {
    let domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}

struct PopoverView: View {
    @ObservedObject var model: Model
    @State private var section = 0
    @State private var tab = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = model.snap
        VStack(alignment: .leading, spacing: 12) {
            header(s)
            rings(s)
            Picker("", selection: $section) {
                Text(L("Overview")).tag(0)
                Text(L("Sessions")).tag(1)
                Text(L("Processes")).tag(2)
                Text(L("History")).tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch section {
                case 1: sessionsSection(s)
                case 2: processesSection(s)
                case 3: historySection
                default: overviewSection(s)
                }
            }
            .transition(.opacity)
        }
        .padding(14)
        .frame(width: 440)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: section)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    // MARK: Header

    private func header(_ s: Snapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(L("Nabd")).font(.system(size: 15, weight: .bold))
            Label(L("Thermal: %@", s.thermal.localized), systemImage: s.tempLevel == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(s.tempLevel == .ok ? Color.green : s.tempLevel.color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill((s.tempLevel == .ok ? Color.green : s.tempLevel.color).opacity(0.14)))
            if let update = model.update {
                Button { NSWorkspace.shared.open(update.url) } label: {
                    Label(L("Update %@", update.version), systemImage: "arrow.down.circle.fill").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help(L("A newer version is on GitHub"))
            }
            Spacer()
            Text(L("Up %@", fmtDuration(s.uptime))).font(.system(size: 10)).foregroundStyle(.secondary)
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Menu(L("Show in Menu Bar")) {
                Toggle(L("Temperature"), isOn: $model.barTemp)
                Toggle(L("CPU"), isOn: $model.barCPU)
                Toggle(L("GPU"), isOn: $model.barGPU)
                Toggle(L("Memory"), isOn: $model.barRAM)
                Toggle(L("Network"), isOn: $model.barNet)
                Toggle(L("Power"), isOn: $model.barPower)
            }
            Toggle(L("Start at Login"), isOn: Binding(get: { model.loginItem }, set: { model.setLoginItem($0) }))
            Toggle(L("Check for Updates Automatically"), isOn: $model.checkUpdates)
            Divider()
            Button(L("Open in Window")) { model.onOpenWindow?() }
            Button(L("Open Activity Monitor")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Button(L("Nabd on GitHub")) { NSWorkspace.shared.open(URL(string: "https://github.com/amjadArqan/nabd")!) }
            Divider()
            Button(L("Quit Nabd")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Settings"))
        .accessibilityLabel(L("Settings"))
    }

    // MARK: Rings

    private func rings(_ s: Snapshot) -> some View {
        let temp = s.temps.cpu
        let fan = s.temps.fans.max { $0.rpm < $1.rpm }
        let power = s.power
        let draw = power?.draw
        let capacity = power?.adapterWatts ?? 100
        return HStack(alignment: .top, spacing: 2) {
            Ring(caption: L("Temperature"), value: temp.map { ltr(String(format: "%.0f°", $0)) } ?? "—",
                 fraction: ((temp ?? 30) - 30) / 70, level: s.tempLevel,
                 detail: fan.map { L("Fans %@", ltr(String(format: "%.0f%%", $0.fraction * 100))) }
                    ?? s.temps.cpuMax.map { L("Peak %@", ltr(String(format: "%.0f°", $0))) } ?? "")
            Ring(caption: L("CPU"), value: ltr(fmtPct(s.cpuTotal)), fraction: s.cpuTotal / 100, level: s.cpuLevel,
                 detail: L("Load %@", ltr(String(format: "%.1f", s.load[0]))))
            if let gpu = s.gpu {
                Ring(caption: L("GPU"), value: ltr(fmtPct(gpu)), fraction: gpu / 100, level: .ok,
                     detail: s.temps.gpu.map { ltr(String(format: "%.0f°", $0)) } ?? "")
            }
            Ring(caption: L("Memory"), value: ltr(fmtPct(s.mem.percent)), fraction: s.mem.percent / 100, level: s.memLevel,
                 detail: L("Swap %@", ltr(fmtBytes(s.mem.swapUsed))))
            if power != nil {
                Ring(caption: L("Power"), value: draw.map { ltr(String(format: "%.0fW", $0)) } ?? "—",
                     fraction: (draw ?? 0) / capacity, level: .ok,
                     detail: power?.plugged == true ? L("of %@", ltr(String(format: "%.0fW", capacity))) : L("Battery"))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    // MARK: Overview

    private func overviewSection(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ioCard(s)
            if let power = s.power { powerCard(power) }
            adviceCard(s)
            guardCard
        }
    }

    private func ioCard(_ s: Snapshot) -> some View {
        func column(_ title: String, _ symbol: String, _ lines: [(String, String)]) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Text(lines[i].0).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(ltr(lines[i].1)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let rate = { (v: Double?) in v.map { fmtRate($0) } ?? "—" }
        return Card {
            HStack(alignment: .top, spacing: 10) {
                column(L("Network"), "network", [("↓", rate(s.netIn)), ("↑", rate(s.netOut))])
                Divider()
                column(L("Disk"), "internaldrive", [(L("Read"), rate(s.diskRead)), (L("Write"), rate(s.diskWrite))])
                Divider()
                column(L("Storage"), "externaldrive", [(L("Free"), s.diskFree.map(fmtDisk) ?? "—"),
                                                     (L("Total"), s.diskTotal.map(fmtDisk) ?? "—")])
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func powerCard(_ p: PowerInfo) -> some View {
        let draw = p.draw ?? 0
        let w = { (v: Double) in ltr(String(format: v < 10 ? "%.1fW" : "%.0fW", v)) }
        let energy = model.energyToday >= 1000 ? String(format: "%.2f kWh", model.energyToday / 1000) : String(format: "%.0f Wh", model.energyToday)
        var battery: [String] = []
        if let percent = p.percent { battery.append(L("Battery %@", ltr("\(percent)%"))) }
        if let health = p.health { battery.append(L("Health %@", ltr(String(format: "%.0f%%", health)))) }
        if let cycles = p.cycles { battery.append(L("%@ cycles", String(cycles))) }
        if !p.plugged, let minutes = p.minutesLeft { battery.append(L("%@ left", fmtDuration(TimeInterval(minutes * 60)))) }
        return Card {
            HStack(spacing: 5) {
                Image(systemName: p.plugged ? "bolt.fill" : "battery.75percent").foregroundStyle(p.plugged ? Color.yellow : Color.secondary)
                    .accessibilityHidden(true)
                Text(p.plugged ? L("Power from the charger") : L("On battery")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(rtl(L("Peak %@ · Today %@", w(model.powerPeak), ltr(energy)))).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let rating = p.adapterWatts, rating > 0 {
                // How much of the charger's capacity is in use, split by where it goes.
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        let scale = geo.size.width / rating
                        Rectangle().fill(Color.accentColor).frame(width: max(0, (p.system ?? draw) * scale))
                        if let battery = p.battery, battery > 0 { Rectangle().fill(Color.green).frame(width: battery * scale) }
                        if let loss = p.loss { Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: loss * scale) }
                        Spacer(minLength: 0)
                    }
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: draw)
            }
            HStack(spacing: 12) {
                if let system = p.system { legend(Color.accentColor, L("Mac %@", w(system))) }
                if p.plugged, let charge = p.battery, abs(charge) >= 0.5 {
                    legend(charge > 0 ? Color.green : Color.orange, charge > 0 ? L("Charging %@", w(charge)) : L("From battery %@", w(-charge)))
                }
                if p.plugged, let loss = p.loss, loss >= 0.1 { legend(Color.secondary.opacity(0.6), L("Charger loss %@", w(loss))) }
            }
            if !battery.isEmpty {
                Text(rtl(battery.joined(separator: " · "))).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(rtl(text)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func adviceCard(_ s: Snapshot) -> some View {
        if s.advice.isEmpty {
            Card {
                Label(L("All good"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
            }
        } else {
            Card {
                sectionTitle(L("Suggestions"))
                ForEach(s.advice.prefix(3)) { a in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: a.level == .ok ? "lightbulb.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(a.level == .ok ? Color.yellow : a.level.color)
                            .frame(width: 14)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rtl(a.title)).font(.system(size: 12, weight: .medium))
                            Text(rtl(a.detail)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true).help(a.detail)
                        }
                        Spacer(minLength: 0)
                        if !a.killPids.isEmpty {
                            Button(L("Quit")) { model.confirmKill(a.title, detail: a.detail, pids: a.killPids) }.controlSize(.small)
                        }
                    }
                }
                if s.advice.count > 3 {
                    Text(rtl(L("%@ more — full details with %@", String(s.advice.count - 3), ltr("nabd doctor")))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var guardCard: some View {
        let g = model.guardStatus
        let limit = model.guardLimit
        let waiting = g.paused.count
        let status: String
        if limit == 0 {
            status = waiting > 0 ? L("Off. Sessions you paused: %@.", String(waiting)) : L("Off: nothing is paused automatically.")
        } else if waiting > 0 {
            status = L("Paused sessions: %@. They continue when the CPU drops below %@, or after 5 minutes at most.",
                       String(waiting), ltr("\(limit - Int(Guard.margin))%"))
        } else {
            status = L("If the CPU stays at %@ or more for 12 seconds, the heaviest Claude Code session pauses until things calm down.", ltr("\(limit)%"))
        }
        return Card {
            HStack(spacing: 6) {
                Image(systemName: limit > 0 ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(limit > 0 ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(L("Guard")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(L("Limit"), selection: $model.guardLimit) {
                    Text(L("Off")).tag(0)
                    ForEach(model.limitChoices, id: \.self) { Text(ltr("\($0)%")).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text(rtl(status)).font(.system(size: 11)).foregroundStyle(waiting > 0 ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if waiting > 0 {
                HStack {
                    Button(L("Show Sessions")) { section = 1 }.controlSize(.small)
                    Button(L("Force Continue All")) { model.forceContinue(nil) }.controlSize(.small).keyboardShortcut(.defaultAction)
                    Spacer()
                }
            }
        }
    }

    // MARK: Sessions

    private func numbers(cpu: Double, mem: UInt64) -> some View {
        HStack(spacing: 0) {
            Text(ltr(fmtPct(cpu))).frame(width: 46, alignment: .trailing)
            Text(ltr(fmtBytes(mem))).frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private func columnHeader(_ title: String) -> some View {
        HStack(spacing: 0) {
            sectionTitle(title)
            Spacer()
            Text(L("CPU")).frame(width: 46, alignment: .trailing)
            Text(L("Memory")).frame(width: 60, alignment: .trailing)
            Spacer().frame(width: 50)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    @ViewBuilder private func sessionsSection(_ s: Snapshot) -> some View {
        if let p = s.procs {
            VStack(alignment: .leading, spacing: 4) {
                columnHeader(rtl(L("Sessions: %@ · MCP servers: %@", String(p.sessions.count), String(p.mcpCount))))
                if p.sessions.isEmpty {
                    Text(L("No Claude Code sessions running")).font(.system(size: 12)).foregroundStyle(.secondary).padding(6)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(p.sessions.sorted { $0.elapsed < $1.elapsed }) { x in sessionRow(x) }
                    }
                }
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: p.sessions.count <= 7)
                if let d = p.desktop {
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/Claude.app"))
                                .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                            Text(rtl(L("Claude app · %@ processes", String(d.pids.count)))).font(.system(size: 12))
                        }
                        Spacer(minLength: 4)
                        numbers(cpu: d.cpu, mem: d.mem)
                        Spacer().frame(width: 50)
                    }
                    .padding(.horizontal, 6)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
        }
    }

    private func sessionRow(_ x: ClaudeSession) -> some View {
        let pause = model.guardStatus.paused.first { $0.root == x.id }
        return HStack(spacing: 8) {
            Image(systemName: pause != nil ? "pause.circle.fill" : (x.idle ? "moon.zzz.fill" : "terminal.fill"))
                .font(.system(size: 13))
                .foregroundStyle(pause != nil ? Color.orange : (x.idle ? Color.secondary : Color.accentColor))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(ltr(x.label)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(rtl(subtitle(x, pause: pause))).font(.system(size: 10))
                    .foregroundStyle(pause != nil ? Color.orange : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            numbers(cpu: x.cpu, mem: x.mem)
            HStack(spacing: 2) {
                if pause != nil {
                    IconButton(symbol: "play.fill", label: L("Force continue (won't pause again for 15 minutes)"), tint: .green) { model.forceContinue(x.id) }
                } else {
                    IconButton(symbol: "pause.fill", label: L("Pause this session's work until you continue it")) { model.pause(x.id) }
                }
                IconButton(symbol: "xmark", label: L("Quit session")) {
                    model.confirmKill(L("Claude Code session “%@”", x.label),
                                      detail: L("The session closes along with the processes it started (%@). The conversation is saved and can be resumed.", String(x.pids.count - 1)),
                                      pids: x.pids)
                }
            }
            .frame(width: 50, alignment: .trailing)
        }
        .modifier(HoverRow())
    }

    private func subtitle(_ x: ClaudeSession, pause: Guard.Paused?) -> String {
        if let pause {
            let waited = max(0, Int(Date().timeIntervalSince(pause.since)))
            let since = waited < 60 ? L("%@ s", String(waited)) : fmtDuration(TimeInterval(waited))
            if pause.manual { return L("Paused by you %@ ago · waiting for you to continue", since) }
            return L("Paused %@ ago · ", since) + (pause.hot ? L("until the Mac cools down") : L("until the CPU calms down"))
        }
        var parts = [L("Up %@", fmtDuration(x.elapsed)), ltr("MCP \(x.mcpCount)")]
        if let top = x.topName { parts.append(L("Heaviest %@", ltr("\(top) \(fmtPct(x.topCPU))"))) }
        if x.idle { parts.append(x.quietFor > 600 ? L("Idle for %@", fmtDuration(x.quietFor)) : L("Idle")) }
        if model.guardStatus.exempt.contains(x.id) { parts.append(L("Won't be paused")) }
        if x.calm { parts.append(L("Background priority (slow)")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Processes

    @ViewBuilder private func processesSection(_ s: Snapshot) -> some View {
        if let p = s.procs {
            let rows: [ProcGroup] = {
                switch tab {
                case 1: return Array(p.groups.sorted { $0.mem > $1.mem }.prefix(8))
                case 2: return Array(p.groups.filter { ProcessScanner.devServices.contains($0.name) }
                        .sorted { ($0.cpu, Double($0.mem)) > ($1.cpu, Double($1.mem)) }.prefix(8))
                default: return Array(p.groups.sorted { $0.cpu > $1.cpu }.prefix(8))
                }
            }()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("", selection: $tab) {
                        Text(L("CPU")).tag(0)
                        Text(L("Memory")).tag(1)
                        Text(L("Dev Services")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                    Text(L("%@ processes", String(p.total))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                columnHeader(L("App"))
                ForEach(rows) { g in
                    HStack(spacing: 8) {
                        Text(ltr(g.name + (g.pids.count > 1 ? " ×\(g.pids.count)" : ""))).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        if g.calm { Image(systemName: "leaf.fill").font(.system(size: 9)).foregroundStyle(.green).accessibilityLabel(L("Background priority")) }
                        Spacer(minLength: 4)
                        numbers(cpu: g.cpu, mem: g.mem)
                        HStack(spacing: 2) {
                            if g.mine, !ProcessScanner.protected.contains(g.name), g.name != "Claude Code" {
                                IconButton(symbol: g.calm ? "leaf.fill" : "leaf",
                                           label: g.calm ? L("Back to full speed") : L("Calm: move to the efficiency cores (cooler, slower)"),
                                           tint: g.calm ? .green : .secondary) { model.toggleCalm(g.pids, isCalm: g.calm) }
                                IconButton(symbol: "xmark", label: L("Quit")) {
                                    model.confirmKill(g.name, detail: L("A quit request goes to every process in it (%@). Save your work first.", String(g.pids.count)), pids: g.pids)
                                }
                            }
                        }
                        .frame(width: 50, alignment: .trailing)
                    }
                    .modifier(HoverRow())
                }
                if rows.isEmpty { Text(L("No services running")).font(.system(size: 11)).foregroundStyle(.secondary).padding(6) }
                Text(rtl(L("CPU: %@ = one full core", ltr("100%")))).font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 6)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
        }
    }

    // MARK: History

    private var historySection: some View {
        let points = model.history
        let last = points.last
        let pct = { (v: Double?) in v.map { ltr(fmtPct($0)) } ?? "—" }
        return VStack(alignment: .leading, spacing: 12) {
            if points.count < 3 {
                Text(L("Collecting readings… the charts fill in over the next minutes.")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            MiniChart(title: L("CPU and GPU"), current: rtl(L("CPU %@ · GPU %@", pct(last?.cpu), pct(last?.gpu))), points: points,
                      series: [(L("CPU"), Color.accentColor, { $0.cpu }), (L("GPU"), Color.purple, { $0.gpu })], domain: 0...100)
            MiniChart(title: L("Temperature"), current: last?.temp.map { ltr(String(format: "%.0f°", $0)) } ?? "—", points: points,
                      series: [(L("Temperature"), Color.orange, { $0.temp })])
            MiniChart(title: L("Memory"), current: pct(last?.mem), points: points,
                      series: [(L("Memory"), Color.teal, { $0.mem })], domain: 0...100)
            if points.contains(where: { $0.power != nil }) {
                MiniChart(title: L("Power"), current: last?.power.map { ltr(String(format: "%.0fW", $0)) } ?? "—", points: points,
                          series: [(L("Power"), Color.yellow, { $0.power })])
            }
            MiniChart(title: L("Network"), current: ltr("↓\(last?.netIn.map { fmtRate($0) } ?? "—")  ↑\(last?.netOut.map { fmtRate($0) } ?? "—")"), points: points,
                      series: [("↓", Color.accentColor, { $0.netIn.map { $0 / 1_048_576 } }), ("↑", Color.green, { $0.netOut.map { $0 / 1_048_576 } })])
            Text(L("Last 30 minutes · network in MB/s")).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Toast (an alert of our own: macOS refuses notification permission to an ad-hoc signed app)

struct ToastView: View {
    let title: String
    let message: String
    let onContinue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill").font(.system(size: 26)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(rtl(title)).font(.system(size: 13, weight: .semibold))
                Text(rtl(message)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Force Continue"), action: onContinue)
                    Button(L("Dismiss"), action: onDismiss)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }
}

/// The toast floats over other apps without taking focus, so its buttons must react to the very first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Toast {
    private var panel: NSPanel?
    private var timer: Timer?

    func show(title: String, message: String, onContinue: @escaping () -> Void) {
        dismiss()
        let view = FirstMouseHostingView(rootView: ToastView(title: title, message: message, onContinue: { [weak self] in
            onContinue()
            self?.dismiss()
        }, onDismiss: { [weak self] in self?.dismiss() }))
        let size = view.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NSSound(named: "Glass")?.play()
        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in self?.dismiss() }
        // Readable with `defaults read local.nabd.monitor lastAlert`.
        UserDefaults.standard.set("\(Date()) · \(message) · frame \(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)", forKey: "lastAlert")
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private let model = Model()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var activity: NSObjectProtocol?
    private var termination: DispatchSourceSignal?
    private let toast = Toast()
    private var window: NSWindow?
    private var notificationsAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, App Nap stretches the timers of a windowless app and the guard reacts late.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching system load")
        // A plain SIGTERM (pkill, logout) would skip applicationWillTerminate and leave held jobs throttled.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Nabd")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        model.onUpdate = { [weak self] in self?.updateTitle() }
        model.onPause = { [weak self] item, label, cpu in self?.announce(item, label: label, cpu: cpu) }
        model.onOpenWindow = { [weak self] in self?.openWindow() }
        setUpNotifications()
        // `nabd continue` from a terminal.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.nabd.monitor.continue"), object: nil, queue: .main) { [weak self] _ in
            self?.model.forceContinue(nil)
        }
        model.start()
        // `nabd window` starts the app with its window open.
        if CommandLine.arguments.contains("window") { DispatchQueue.main.async { self.openWindow() } }
        // `nabd open` starts the app with its panel already showing.
        guard CommandLine.arguments.contains("open") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let window = self.statusItem.button?.window else { return }
            self.togglePopover()
            let size = self.popover.contentViewController?.view.frame.size ?? .zero
            print("status item x=\(Int(window.frame.minX)) width=\(Int(window.frame.width)) onscreen=\(window.occlusionState.contains(.visible))"
                + " · panel shown=\(self.popover.isShown) size=\(Int(size.width))×\(Int(size.height))")
            fflush(stdout)
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let s = model.snap
        let paused = model.guardStatus.paused.count
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        // Leave the default color alone when all is well so the text follows the menu bar's own appearance.
        if s.level != .ok || paused > 0 { attributes[.foregroundColor] = s.level == .crit ? NSColor.systemRed : NSColor.systemOrange }
        button.image = NSImage(systemSymbolName: paused > 0 ? "pause.circle.fill" : "waveform.path.ecg",
                               accessibilityDescription: paused > 0 ? "Nabd: \(paused) paused" : "Nabd")
        let text = model.barText
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: attributes)
    }

    // MARK: Notifications

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let proceed = UNNotificationAction(identifier: "continue", title: L("Force Continue"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "paused", actions: [proceed], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            // Readable with `defaults read local.nabd.monitor notifications`.
            UserDefaults.standard.set(granted ? "allowed" : "not allowed" + (error.map { ": \($0.localizedDescription)" } ?? ""), forKey: "notifications")
            DispatchQueue.main.async { self?.notificationsAllowed = granted }
        }
    }

    /// A system notification when macOS allows them for this app, otherwise our own toast. Both carry the
    /// forced-continue button.
    private func announce(_ item: Guard.Paused, label: String, cpu: Double) {
        // `defaults write local.nabd.monitor muteAlerts -bool true` keeps the guard working silently.
        if UserDefaults.standard.bool(forKey: "muteAlerts") { return }
        let title = L("Nabd paused a session")
        let body = (item.hot ? L("The Mac is hot.") : L("The CPU reached %@.", ltr("\(Int(cpu.rounded()))%"))) + " " + L("It continues when things calm down, or choose Force Continue.")
        guard notificationsAllowed else {
            let root = item.root
            return toast.show(title: title, message: L("“%@”: ", ltr(label)) + body) { [weak self] in self?.model.forceContinue(root) }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = label
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "paused"
        content.userInfo = ["root": Int(item.root)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "paused-\(item.root)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "continue", let root = response.notification.request.content.userInfo["root"] as? Int {
            model.forceContinue(Int32(root))
        }
        completionHandler()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { return popover.performClose(nil) }
        // The SwiftUI tree only exists while the popover is open, so a closed Nabd costs almost nothing.
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        model.popoverOpen = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    /// Opening Nabd again from Applications, Launchpad or Spotlight while it runs shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    /// The same panel in an ordinary window, with a Dock icon while it is open.
    func openWindow() {
        popover.performClose(nil)
        if window == nil {
            let host = NSHostingController(rootView: PopoverView(model: model))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = L("Nabd")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            if !w.setFrameUsingName("NabdWindow") { w.center() }
            w.setFrameAutosaveName("NabdWindow")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        model.popoverOpen = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil  // the SwiftUI tree goes with it, as with the popover
        NSApp.setActivationPolicy(.accessory)
        model.popoverOpen = popover.isShown
    }

    /// Dragging the popover away from the menu bar turns it into a floating window.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = window != nil
        popover.contentViewController = nil
    }
}

enum Main {
    static func runApp() {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 { exit(0) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Invented readings for README screenshots, so no real project or app names end up in them.
    static func fillDemo(_ model: Model) {
        let gb: UInt64 = 1_073_741_824
        var s = Snapshot()
        s.cpuTotal = 46; s.cpuP = 38; s.cpuE = 80; s.load = [6.2, 7.1, 6.8]; s.ncpu = 10
        s.mem = MemInfo(total: 16 * gb, app: 6 * gb, wired: 2 * gb, compressed: 3 * gb, cached: 2 * gb, swapUsed: 2 * gb, swapTotal: 4 * gb, pressure: 1)
        s.temps = Temps(cpu: 64, cpuMax: 72, gpu: 52, battery: 33, ssd: 38, fans: [Fan(rpm: 2600, min: 1500, max: 4300)])
        s.uptime = 2 * 86400 + 3 * 3600
        s.power = PowerInfo(plugged: true, charging: true, adapterWatts: 140, adapterName: "140W USB-C Power Adapter",
                            input: 41.2, system: 33.6, battery: 6.8, loss: 0.8, percent: 86)
        func session(_ id: Int32, _ label: String, hours: Double, cpu: Double, mem: Double, mcp: Int, top: String? = nil, topCPU: Double = 0, idle: Bool = false) -> ClaudeSession {
            ClaudeSession(id: id, label: label, cwd: "/Users/me/code/\(label)", elapsed: hours * 3600, cpu: cpu, mem: UInt64(mem * Double(gb)),
                          pids: [id], mcpCount: mcp, topName: top, topCPU: topCPU, quietFor: idle ? 7200 : 0, idle: idle)
        }
        var report = ProcReport(total: 642)
        report.sessions = [session(9001, "my-saas-app", hours: 5.2, cpu: 112, mem: 1.4, mcp: 2, top: "php", topCPU: 96),
                           session(9002, "landing-page", hours: 1.1, cpu: 8, mem: 0.6, mcp: 1),
                           session(9003, "api-server", hours: 3.4, cpu: 0, mem: 0.7, mcp: 2),
                           session(9004, "docs", hours: 26, cpu: 0, mem: 0.4, mcp: 1, idle: true)]
        report.mcpCount = 6
        report.mcpMem = UInt64(0.4 * Double(gb))
        report.groups = [ProcGroup(name: "Arc", cpu: 18, mem: 3 * gb, pids: Array(1...24), mine: true),
                         ProcGroup(name: "php", cpu: 104, mem: UInt64(0.9 * Double(gb)), pids: Array(1...6), mine: true),
                         ProcGroup(name: "Claude", cpu: 22, mem: UInt64(2.1 * Double(gb)), pids: Array(1...28), mine: true),
                         ProcGroup(name: "WindowServer", cpu: 31, mem: UInt64(0.1 * Double(gb)), pids: [1], mine: false),
                         ProcGroup(name: "node", cpu: 12, mem: UInt64(0.8 * Double(gb)), pids: Array(1...9), mine: true),
                         ProcGroup(name: "Claude Code", cpu: 6, mem: UInt64(1.6 * Double(gb)), pids: Array(1...4), mine: true),
                         ProcGroup(name: "mysqld", cpu: 2, mem: UInt64(0.5 * Double(gb)), pids: [1], mine: true),
                         ProcGroup(name: "redis-server", cpu: 0.4, mem: 8 * 1_048_576, pids: [1], mine: true)]
        s.gpu = 22
        s.netIn = 1.4 * 1_048_576; s.netOut = 180 * 1024
        s.diskRead = 12 * 1_048_576; s.diskWrite = 3.4 * 1_048_576
        s.diskFree = 212 * gb; s.diskTotal = 494 * gb
        s.power?.health = 91; s.power?.cycles = 212
        s.procs = report
        s.advice = Advisor.advise(s)
        // Half an hour of made-up history with a build spike in the middle.
        let start = Date().addingTimeInterval(-1800)
        model.history = (0..<300).map { i in
            let t = Double(i) / 300, spike = exp(-pow((t - 0.55) * 9, 2))
            return HistoryPoint(time: start.addingTimeInterval(Double(i) * 6), cpu: 30 + 55 * spike + 6 * sin(Double(i) / 7), gpu: 15 + 10 * sin(Double(i) / 11),
                                temp: 55 + 22 * spike, mem: 66 + 4 * t, power: 28 + 45 * spike, netIn: (0.6 + 0.8 * abs(sin(Double(i) / 9))) * 1_048_576,
                                netOut: (0.1 + 0.15 * abs(cos(Double(i) / 13))) * 1_048_576)
        }
        model.snap = s
        model.powerPeak = 78
        model.energyToday = 186
        model.guardStatus = Guard.Status(cpu: 46, paused: [Guard.Paused(root: 9003, since: Date().addingTimeInterval(-42), manual: false, hot: false)])
    }

    /// Renders the popover offscreen to a PNG, for checking the layout without opening the menu.
    static func renderSnapshot(to path: String, dark: Bool, tab: Int, demo: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let model = Model()
        if demo == "readme" { fillDemo(model) } else { model.fillSynchronously(samples: demo == "toast" ? 1 : 8) }
        // Demo states exist only for these renders: they show a layout without pausing anything for real.
        if demo == "paused", let sessions = model.snap.procs?.sessions, let first = sessions.first {
            var paused = [Guard.Paused(root: first.id, since: Date().addingTimeInterval(-42), manual: false, hot: false)]
            if let second = sessions.dropFirst().first { paused.append(Guard.Paused(root: second.id, since: Date().addingTimeInterval(-200), manual: true, hot: false)) }
            model.guardStatus = Guard.Status(cpu: 62, paused: paused, exempt: sessions.dropFirst(2).prefix(1).map(\.id))
        }
        let view: NSView = demo == "toast"
            ? NSHostingView(rootView: ToastView(title: L("Nabd paused a session"), message: L("“%@”: ", "my-project") + L("The CPU reached %@.", "97%") + " " + L("It continues when things calm down, or choose Force Continue."), onContinue: {}, onDismiss: {}).padding(12).background(Color(nsColor: .windowBackgroundColor)))
            : NSHostingView(rootView: PopoverView(model: model, initialTab: tab).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil else { exit(1) }
        print("wrote \(path) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
    }

    static func run() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
        switch args.first {
        case nil, "open", "window": runApp()
        case "status": CLI.status()
        case "doctor": CLI.printAdvice(CLI.snapshot())
        case "line": print(CLI.line(CLI.snapshot()))
        case "json": CLI.json()
        case "sensors": CLI.sensors()
        case "guard": CLI.guardReport(limit: args.count > 1 ? Int(args[args.startIndex + 1]) ?? 90 : 90)
        case "continue": CLI.forceContinue()
        case "log": CLI.guardLog()
        case "login": CLI.login(args.count > 1 ? args[args.startIndex + 1] : nil)
        case "calm", "uncalm":
            guard args.count > 1 else { return CLI.usage() }
            CLI.calm(Array(args.dropFirst()), on: args.first == "calm")
        case "--snapshot":
            guard args.count > 1 else { return CLI.usage() }
            let tab = args.firstIndex(of: "--tab").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
            let demo = args.firstIndex(of: "--demo").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            renderSnapshot(to: args[args.startIndex + 1], dark: args.contains("--dark"), tab: tab, demo: demo)
        default: CLI.usage()
        }
    }
}

extension PopoverView {
    init(model: Model, initialTab: Int) {
        self.model = model
        _section = State(initialValue: initialTab)
    }
}

Main.run()
