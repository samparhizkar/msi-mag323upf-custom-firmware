// wakebench: measure how long the MSI display takes to come back after display sleep.
// Usage: swift tools/wakebench.swift [runs=3] [sleepSeconds=30]
import Foundation
import CoreGraphics
import IOKit.pwr_mgt

let msiVendor: UInt32 = 0x3669   // EDID manufacturer "MSI"
let args = CommandLine.arguments
let runs = args.count > 1 ? Int(args[1]) ?? 3 : 3
let sleepSeconds = args.count > 2 ? Double(args[2]) ?? 30 : 30

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func msiDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).first { CGDisplayVendorNumber($0) == msiVendor }
}

struct State: Equatable { var online: Bool; var active: Bool; var asleep: Bool }
func state() -> State {
    guard let d = msiDisplay() else { return State(online: false, active: false, asleep: true) }
    return State(online: true, active: CGDisplayIsActive(d) != 0, asleep: CGDisplayIsAsleep(d) != 0)
}

// Log reconfiguration callbacks (hotplug / mode set) with timestamps relative to the wake request.
var t0 = 0.0
var events: [(Double, String)] = []
CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
    guard CGDisplayVendorNumber(id) == msiVendor else { return }
    var f: [String] = []
    if flags.contains(.beginConfigurationFlag) { f.append("begin") }
    if flags.contains(.addFlag) { f.append("add") }
    if flags.contains(.removeFlag) { f.append("remove") }
    if flags.contains(.enabledFlag) { f.append("enabled") }
    if flags.contains(.disabledFlag) { f.append("disabled") }
    if flags.contains(.setModeFlag) { f.append("setMode") }
    if flags.contains(.desktopShapeChangedFlag) { f.append("shape") }
    events.append((now() - t0, f.joined(separator: ",")))
}, nil)

func pump(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

guard msiDisplay() != nil else { print("MSI display not online"); exit(1) }
print("runs=\(runs) sleep=\(sleepSeconds)s")
var results: [Double] = []
var ddcResults: [Double] = []
let av = externalAVService()
print("DDC: \(av == nil ? "unavailable" : "ok")")

for run in 1...runs {
    events.removeAll()
    let p = Process(); p.launchPath = "/usr/bin/pmset"; p.arguments = ["displaysleepnow"]; p.launch(); p.waitUntilExit()
    let sleepStart = now()
    var sleptAt: Double? = nil
    var standby: [String] = []
    while now() - sleepStart < sleepSeconds {
        if sleptAt == nil && state().asleep { sleptAt = now() - sleepStart }
        if let svc = av, standby.count < 3, now() - sleepStart > sleepSeconds - 3 {
            standby.append(getVCP(svc, 0xD6).map { "D6=\($0.0)" } ?? "no reply"); usleep(200_000)
        }
        pump(0.05)
    }
    // Wake: declare user activity.
    var assertion: IOPMAssertionID = 0
    t0 = now()
    IOPMAssertionDeclareUserActivity("wakebench" as CFString, kIOPMUserActiveLocal, &assertion)
    var firstOnline: Double? = nil, firstAwake: Double? = nil, last = state()
    var ddcFirstReply: Double? = nil, ddcOn: Double? = nil, ddcLast: UInt16? = 999, ddcLog: [(Double, String)] = []
    var lastPoll = -1.0
    var transitions: [(Double, State)] = [(0, last)]
    while now() - t0 < 20 {
        let s = state(), t = now() - t0
        if s != last { transitions.append((t, s)); last = s }
        if s.online && firstOnline == nil { firstOnline = t }
        if s.online && s.active && !s.asleep && firstAwake == nil { firstAwake = t }
        if let svc = av, t - lastPoll >= 0.05, ddcOn == nil {
            lastPoll = t
            let r = getVCP(svc, 0xD6, replyDelay: 30_000)
            let tr = now() - t0
            if r != nil && ddcFirstReply == nil { ddcFirstReply = tr }
            if r?.0 == 1 && ddcOn == nil { ddcOn = tr }
            if r?.0 != ddcLast { ddcLog.append((tr, r.map { "D6=\($0.0)" } ?? "no reply")); ddcLast = r?.0 }
        }
        if firstAwake != nil && (ddcOn != nil || av == nil) && t > max(firstAwake!, ddcOn ?? 0) + 2 { break }
        pump(0.005)
    }
    IOPMAssertionRelease(assertion)
    print(String(format: "run %d: asleep after %.2fs | online %@ | awake %@",
                 run, sleptAt ?? -1,
                 firstOnline.map { String(format: "%.3fs", $0) } ?? "never",
                 firstAwake.map { String(format: "%.3fs", $0) } ?? "never"))
    print("   standby DDC: \(standby.joined(separator: ", "))")
    print(String(format: "   DDC first reply %@ | DDC power on %@",
                 ddcFirstReply.map { String(format: "%.3fs", $0) } ?? "never",
                 ddcOn.map { String(format: "%.3fs", $0) } ?? "never"))
    for (t, e) in ddcLog { print(String(format: "   %.3fs ddc %@", t, e)) }
    if let d = ddcOn { ddcResults.append(d) }
    for (t, s) in transitions { print(String(format: "   %.3fs state online=%d active=%d asleep=%d", t, s.online ? 1 : 0, s.active ? 1 : 0, s.asleep ? 1 : 0)) }
    for (t, e) in events { print(String(format: "   %.3fs cg %@", t, e)) }
    if let a = firstAwake { results.append(a) }
    pump(5)
}
if !results.isEmpty {
    let s = results.sorted()
    print(String(format: "macOS awake: min %.3fs median %.3fs max %.3fs", s.first!, s[s.count / 2], s.last!))
}
if !ddcResults.isEmpty {
    let s = ddcResults.sorted()
    print(String(format: "monitor on (DDC): min %.3fs median %.3fs max %.3fs", s.first!, s[s.count / 2], s.last!))
}
