// App benchmark: cold launch, first paint, memory, idle CPU and idle wakeups for Markdown editors.
//
// Build: swiftc -O bench/AppBench.swift -o build/appbench
// Run:   build/appbench <out.json> <smallNote.md> <largeNote.md> <App.app>...
//
// For every app and run: the app is quit, then launched with the note (as Finder would do it),
// and we record
//   window    – time until its first window (≥ 200 pt tall) is on screen;
//   painted   – time until the window stops changing (last visual change; ScreenCaptureKit, ~30 ms steps);
//   memory    – phys_footprint summed over every process the app is responsible for (helpers, WebKit), 5 s after launch;
//   idle CPU  – CPU time of those processes over the next 10 s, as % of one core (window in view, no input);
//   wakeups   – interrupt wakeups per second over the same 10 s.
// Apps that are already running when the benchmark starts are skipped, so nothing the user has open is quit.

import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Process helpers

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func machToSeconds(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

func allPIDs() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(count))).filter { $0 > 0 }
}

func parentPID(_ pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return size > 0 ? pid_t(info.pbi_ppid) : 0
}

/// The app's process plus everything it is responsible for (Electron helpers, WebKit XPC services).
func processTree(of root: pid_t) -> [pid_t] {
    var result: Set<pid_t> = [root]
    let pids = allPIDs()
    for p in pids {
        if let f = responsibleFn, f(p) == root { result.insert(p) }
    }
    // Plain descendants as a fallback.
    var changed = true
    while changed {
        changed = false
        for p in pids where !result.contains(p) && result.contains(parentPID(p)) {
            result.insert(p); changed = true
        }
    }
    return Array(result)
}

struct Usage { var cpu: Double; var wakeups: UInt64; var footprint: UInt64 }

func usage(_ pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr -> Bool in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0 }
    }
    guard ok else { return nil }
    return Usage(cpu: machToSeconds(info.ri_user_time + info.ri_system_time),
                 wakeups: info.ri_interrupt_wkups, footprint: info.ri_phys_footprint)
}

// MARK: - Windows and screen capture

func firstWindowID(of pid: pid_t) -> CGWindowID? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let h = b["Height"] as? Double, h >= 200 else { continue }
        return w[kCGWindowNumber as String] as? CGWindowID
    }
    return nil
}

func sync<T>(_ body: @escaping () async throws -> T) -> T? {
    var result: T?
    let sem = DispatchSemaphore(value: 0)
    Task.detached { result = try? await body(); sem.signal() }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    return result
}

func scWindow(_ id: CGWindowID) -> SCWindow? {
    for _ in 0..<50 {
        if let content = sync({ try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }),
           let w = content.windows.first(where: { $0.windowID == id }) { return w }
        usleep(20_000)
    }
    return nil
}

/// Small grayscale thumbnail used to detect visual changes.
func thumbnail(_ window: SCWindow) -> [UInt8]? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    config.width = 320
    config.height = Int(320 * window.frame.height / max(1, window.frame.width))
    config.showsCursor = false
    guard let image = sync({ try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }) else { return nil }
    let w = 160, h = 100
    var pixels = [UInt8](repeating: 0, count: w * h)
    let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? pixels : nil
}

/// True when more than 0.3 % of the thumbnail changed (ignores the blinking caret). The rightmost
/// strip is skipped: scroll bars resize while background layout measures a long document,
/// which is not content being drawn.
func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    let w = 160, h = 100, skip = 6
    var n = 0
    for y in 0..<h {
        for x in 0..<(w - skip) where abs(Int(a[y * w + x]) - Int(b[y * w + x])) > 10 { n += 1 }
    }
    return Double(n) / Double((w - skip) * h) > 0.003
}

// MARK: - Runs

struct RunResult: Codable {
    var window: Double?
    var painted: Double?
    var memoryMB: Double?
    var idleCPU: Double?
    var wakeups: Double?
}

func quit(_ app: NSRunningApplication) {
    app.terminate()
    let deadline = Date().addingTimeInterval(8)
    while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if !app.isTerminated { app.forceTerminate(); RunLoop.current.run(until: Date().addingTimeInterval(1)) }
}

func runOnce(appURL: URL, file: URL, measureIdle: Bool) -> RunResult {
    var r = RunResult()
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.createsNewApplicationInstance = false
    var launched: NSRunningApplication?
    let t0 = Date()
    NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: config) { app, _ in launched = app }
    var windowID: CGWindowID?
    while Date().timeIntervalSince(t0) < 20 {
        if let app = launched ?? NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: appURL)!.bundleIdentifier!).first {
            launched = app
            if let id = firstWindowID(of: app.processIdentifier) { windowID = id; break }
        }
        usleep(2_000)
    }
    guard let app = launched, let windowID else { if let a = launched { quit(a) }; return r }
    r.window = Date().timeIntervalSince(t0) * 1000

    // Painted: last visual change before 1.5 s of stability (max 12 s).
    if let sw = scWindow(windowID), var previous = thumbnail(sw) {
        var lastChange = Date().timeIntervalSince(t0)
        while Date().timeIntervalSince(t0) < 12 {
            let at = Date().timeIntervalSince(t0)
            guard let current = thumbnail(sw) else { break }
            if differs(previous, current) { lastChange = at }
            previous = current
            if at - lastChange >= 1.5 { break }
        }
        r.painted = max(lastChange * 1000, r.window!)
    }

    if measureIdle {
        let settleUntil = t0.addingTimeInterval(5)
        while Date() < settleUntil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let pids = processTree(of: app.processIdentifier)
        let before = pids.compactMap { p in usage(p).map { (p, $0) } }
        r.memoryMB = Double(before.map(\.1.footprint).reduce(0, +)) / 1_048_576
        let start = Date()
        RunLoop.current.run(until: start.addingTimeInterval(10))
        let elapsed = Date().timeIntervalSince(start)
        var cpu = 0.0, wake: UInt64 = 0
        for (p, b) in before {
            guard let a = usage(p) else { continue }
            cpu += a.cpu - b.cpu
            wake += a.wakeups &- b.wakeups
        }
        r.idleCPU = cpu / elapsed * 100
        r.wakeups = Double(wake) / elapsed
    }
    quit(app)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    return r
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: appbench <out.json> <small.md> <large.md> <App.app>...")
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])
let small = URL(fileURLWithPath: args[2]), large = URL(fileURLWithPath: args[3])
let apps = args[4...].map { URL(fileURLWithPath: $0) }
let smallRuns = Int(ProcessInfo.processInfo.environment["SMALL_RUNS"] ?? "10")!
let idleRuns = Int(ProcessInfo.processInfo.environment["IDLE_RUNS"] ?? "5")!
let largeRuns = Int(ProcessInfo.processInfo.environment["LARGE_RUNS"] ?? "5")!

struct AppReport: Codable {
    var name: String
    var version: String
    var bundleID: String
    var sizeMB: Double
    var small: [RunResult] = []
    var large: [RunResult] = []
    var skipped: String?
}

func bundleSize(_ url: URL) -> Double {
    var total: UInt64 = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += UInt64(v?.totalFileAllocatedSize ?? 0) }
        }
    }
    return Double(total) / 1_000_000
}

var reports: [AppReport] = apps.map { url in
    let b = Bundle(url: url)!
    let name = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
    var r = AppReport(name: name, version: (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?",
                      bundleID: b.bundleIdentifier ?? "", sizeMB: bundleSize(url))
    if !NSRunningApplication.runningApplications(withBundleIdentifier: r.bundleID).isEmpty {
        r.skipped = "was already running"
    }
    return r
}

func save() {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try! enc.encode(reports).write(to: outURL)
}

// Interleave apps run by run so background noise affects them equally.
for run in 0..<max(smallRuns, largeRuns) {
    for i in reports.indices where reports[i].skipped == nil {
        if run < smallRuns {
            let r = runOnce(appURL: apps[i], file: small, measureIdle: run < idleRuns)
            reports[i].small.append(r)
            print("\(reports[i].name) small #\(run + 1): window \(r.window.map { String(format: "%.0f", $0) } ?? "-") ms, painted \(r.painted.map { String(format: "%.0f", $0) } ?? "-") ms, mem \(r.memoryMB.map { String(format: "%.0f", $0) } ?? "-") MB, cpu \(r.idleCPU.map { String(format: "%.2f", $0) } ?? "-") %, wakeups \(r.wakeups.map { String(format: "%.1f", $0) } ?? "-")/s")
        }
        if run < largeRuns {
            let r = runOnce(appURL: apps[i], file: large, measureIdle: false)
            reports[i].large.append(r)
            print("\(reports[i].name) large #\(run + 1): window \(r.window.map { String(format: "%.0f", $0) } ?? "-") ms, painted \(r.painted.map { String(format: "%.0f", $0) } ?? "-") ms")
        }
        save()
    }
}
save()
print("done")
