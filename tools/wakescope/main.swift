// wakescope: measure wake/screen-on readiness across sleep scenarios, for firmware comparison.
// Measures the logical signals that are available without a camera:
//   - during sleep: does the scaler still answer DDC? (deep standby = no, light sleep = yes)
//   - on wake: time until the scaler answers DDC again, time until VCP D6 reads "on",
//     and time until macOS marks the display active.
// It does NOT capture the physical backlight-on instant (that needs a slow-mo video).
//
// Usage: wakescope <label> [shortSleep=15] [longSleep=90] [runs=3]
import Foundation
import CoreGraphics
import IOKit.pwr_mgt

let msiVendor: UInt32 = 0x3669
let args = CommandLine.arguments
let label = args.count > 1 ? args[1] : "run"
let shortSleep = args.count > 2 ? Double(args[2]) ?? 15 : 15
let longSleep  = args.count > 3 ? Double(args[3]) ?? 90 : 90
let runs       = args.count > 4 ? Int(args[4]) ?? 3 : 3

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func pump(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

func msiDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).first { CGDisplayVendorNumber($0) == msiVendor }
}
func macAwake() -> Bool {
    guard let d = msiDisplay() else { return false }
    return CGDisplayIsActive(d) != 0 && CGDisplayIsAsleep(d) == 0
}

guard let svc = externalAVService() else { print("MSI not reachable over DDC"); exit(1) }
func d6() -> UInt16? { getVCP(svc, 0xD6, replyDelay: 25_000)?.0 }   // power mode: 1=on

struct Result { var scalerDuringSleep: String; var wakeDDC: Double?; var wakeD6on: Double?; var macActive: Double? }
var results: [(String, Result)] = []

func runScenario(_ name: String, sleepSeconds: Double) {
    let p = Process(); p.launchPath = "/usr/bin/pmset"; p.arguments = ["displaysleepnow"]; p.launch(); p.waitUntilExit()
    // during sleep: sparse poll (every ~1.5s) to see if the scaler drops off
    let sleepStart = now()
    var answered = 0, polls = 0
    while now() - sleepStart < sleepSeconds {
        if now() - sleepStart > 2 {   // let it settle first
            polls += 1; if d6() != nil { answered += 1 }
        }
        pump(1.5)
    }
    let duringSleep = polls == 0 ? "n/a" : (answered == 0 ? "OFF (deep standby)" : answered == polls ? "ON (light sleep)" : "intermittent \(answered)/\(polls)")
    // wake
    var assertion: IOPMAssertionID = 0
    let t0 = now()
    IOPMAssertionDeclareUserActivity("wakescope" as CFString, kIOPMUserActiveLocal, &assertion)
    var firstDDC: Double? = nil, d6on: Double? = nil, macA: Double? = nil
    while now() - t0 < 12 {
        let t = now() - t0
        if macA == nil && macAwake() { macA = t }
        if let v = d6() {
            if firstDDC == nil { firstDDC = t }
            if d6on == nil && v == 1 { d6on = t }
        }
        if firstDDC != nil && d6on != nil && macA != nil { break }
    }
    IOPMAssertionRelease(assertion)
    let r = Result(scalerDuringSleep: duringSleep, wakeDDC: firstDDC, wakeD6on: d6on, macActive: macA)
    results.append((name, r))
    func f(_ x: Double?) -> String { x.map { String(format: "%.0f ms", $0 * 1000) } ?? "never" }
    print("  [\(name)] scaler-during-sleep: \(duringSleep) | wake→DDC: \(f(firstDDC)) | wake→D6=on: \(f(d6on)) | wake→macOS-active: \(f(macA))")
    pump(6)   // let things settle before next run
}

print("wakescope label=\(label)  (short=\(Int(shortSleep))s long=\(Int(longSleep))s runs=\(runs))")
print("NOTE: measures scaler/DDC + macOS readiness, NOT the physical backlight-on instant (needs slow-mo).")
for i in 1...runs { print("short run \(i):"); runScenario("short-\(i)", sleepSeconds: shortSleep) }
for i in 1...max(1, runs - 1) { print("long run \(i):"); runScenario("long-\(i)", sleepSeconds: longSleep) }

func med(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? -1 : s[s.count/2] }
let ddc = results.compactMap { $0.1.wakeDDC }, d6s = results.compactMap { $0.1.wakeD6on }
print(String(format: "\nSUMMARY [%@]: median wake→DDC %.0f ms, median wake→D6=on %.0f ms", label, med(ddc)*1000, med(d6s)*1000))
print("scaler-during-sleep seen: " + Set(results.map { $0.1.scalerDuringSleep }).joined(separator: ", "))
