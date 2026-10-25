// msi-brightness-sync: mirror the built-in display's brightness to the MSI monitor over DDC/CI.
// Brightness keys, the Control Centre slider and auto-brightness all change the built-in
// display, so the MSI follows all of them. Build together with ../ddc.swift.
// Usage: msi-brightness-sync [--min N] [--max N]   (MSI brightness range mapped to the built-in 0..1)
import CoreGraphics
import Foundation

private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private let getBrightness = unsafeBitCast(dlsym(displayServices, "DisplayServicesGetBrightness"), to: GetBrightnessFn.self)

func intArg(_ name: String, _ fallback: Int) -> Int {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Int(args[i + 1]) else { return fallback }
    return max(0, min(100, v))
}
let minLevel = intArg("--min", 0)
let maxLevel = intArg("--max", 100)

func builtinDisplay() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
}

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("\(ts) \(s)")
}

var service: IOAVServiceRef?
var lastSent = -1

// Any display hot-plug or mode change may invalidate the DDC service; look it up again.
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.enabledFlag) {
        service = nil
        lastSent = -1
    }
}, nil)

func tick() {
    guard let display = builtinDisplay() else { return }   // lid closed: nothing to follow
    var value: Float = 0
    guard getBrightness(display, &value) == 0 else { return }
    let target = Int((Float(minLevel) + Float(maxLevel - minLevel) * value).rounded())
    if target == lastSent { return }
    if service == nil {
        service = externalAVService()
        if service == nil { return }
        log("MSI connected")
    }
    if setVCP(service!, 0x10, UInt16(target)) {
        lastSent = target
    } else {
        log("DDC write failed; will reconnect")
        service = nil
        lastSent = -1
    }
}

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so the launchd log file is written immediately
log("started (MSI range \(minLevel)-\(maxLevel))")
Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in tick() }
RunLoop.main.run()
