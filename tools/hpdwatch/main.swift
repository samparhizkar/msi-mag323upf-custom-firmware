// hpdwatch: does the MSI stay in macOS's display list while the display sleeps?
// If it drops out, the OS treats sleep like an unplug (windows get rearranged on wake).
// Usage: hpdwatch [sleepSeconds=32]
import Foundation
import CoreGraphics
import IOKit.pwr_mgt

func msiState() -> (online: Bool, asleep: Bool) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    guard let d = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == 0x3669 }) else { return (false, false) }
    return (true, CGDisplayIsAsleep(d) != 0)
}

let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 32 : 32
guard msiState().online else { print("MSI is not connected to this Mac; nothing to test"); exit(1) }
let p = Process(); p.launchPath = "/usr/bin/pmset"; p.arguments = ["displaysleepnow"]; p.launch(); p.waitUntilExit()
var missing = 0
for t in 1...seconds {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    let s = msiState(); if !s.online { missing += 1 }
    if t % 4 == 0 { print("t=\(t)s online=\(s.online) asleep=\(s.asleep)") }
}
// Wake, then sample every 20 ms for 8 s: did the display drop out (fake unplug) and when was it back?
var a: IOPMAssertionID = 0
let t0 = Date()
IOPMAssertionDeclareUserActivity("hpdwatch" as CFString, kIOPMUserActiveLocal, &a)
var drops = 0, wasOnline = msiState().online, back: Double? = nil, gone: Double? = nil
while Date().timeIntervalSince(t0) < 8 {
    let on = msiState().online, t = Date().timeIntervalSince(t0)
    if wasOnline && !on { drops += 1; if gone == nil { gone = t } }
    if !wasOnline && on { back = t }
    wasOnline = on
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
}
IOPMAssertionRelease(a)
print(missing == 0 ? "DURING SLEEP: stayed in the display list (no fake unplug)"
                   : "DURING SLEEP: missing in \(missing)/\(seconds) samples (sleep looks like an unplug)")
if drops == 0 { print("ON WAKE: no drop-out (no fake unplug)") }
else { print(String(format: "ON WAKE: dropped out %d time(s), first at %.2f s, back at %@", drops, gone!, back.map { String(format: "%.2f s", $0) } ?? "not within 8 s")) }
