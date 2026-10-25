// isp-probe: READ-ONLY diagnostic for the MSI Gaming Controller HID transport (VID 0x1462 PID 0x3FA4).
// Sends a DDC/CI register-READ (sub-command 0x87) through the HID tunnel and prints the raw reply.
// Never enters ISP mode, never writes flash. Safe while using the monitor.
//
// Usage: isp-probe [--seize] [regHex ...]
import Foundation
import IOKit.hid

let VID = 0x1462, PID = 0x3FA4
let REPORT_ID: UInt8 = 1

func xorFold(_ b: ArraySlice<UInt8>) -> UInt8 { b.reduce(0) { $0 ^ $1 } }

// DDC/CI register-read packet (HID command 0xAA, sub-command 0x87). `len` = payload length (63 or 64).
func regReadPacket(_ reg: UInt16, i2c: Bool, len: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: len)
    p[0] = 0xAA
    p[1] = i2c ? 0x6F : 0x00
    let ddc: [UInt8] = [0x6E, 0x03, 0x87, UInt8(reg >> 8), UInt8(reg & 0xFF)]
    for (i, b) in ddc.enumerated() { p[2 + i] = b }
    p[2 + ddc.count] = xorFold(p[2..<(2 + ddc.count)])
    return p
}

let args = CommandLine.arguments
let seize = args.contains("--seize")
let regs: [UInt16] = args.dropFirst().filter { $0 != "--seize" }.compactMap { UInt16($0, radix: 16) }
let testRegs = regs.isEmpty ? [UInt16(0xF049), 0xF000, 0xC9C9] : regs

final class Dev {
    let dev: IOHIDDevice
    let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    var last: [UInt8]?
    init(_ d: IOHIDDevice) { dev = d; inBuf.initialize(repeating: 0, count: 128) }
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID] as CFDictionary)
guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("no MSI Gaming Controller HID device found"); exit(1)
}
print("found \(set.count) collection(s); seize=\(seize)")

func prop(_ d: IOHIDDevice, _ k: String) -> Int {
    (IOHIDDeviceGetProperty(d, k as CFString) as? Int) ?? -1
}

var devs: [Dev] = []
for d in set {
    let box = Dev(d); devs.append(box)
    let up = prop(d, kIOHIDPrimaryUsagePageKey), u = prop(d, kIOHIDPrimaryUsageKey)
    let maxIn = prop(d, kIOHIDMaxInputReportSizeKey), maxOut = prop(d, kIOHIDMaxOutputReportSizeKey)
    print(String(format: "  collection usagePage=%d usage=%d maxIn=%d maxOut=%d", up, u, maxIn, maxOut))
    IOHIDDeviceRegisterInputReportCallback(d, box.inBuf, 128, { ctx, _, _, _, _, report, len in
        let b = Unmanaged<Dev>.fromOpaque(ctx!).takeUnretainedValue()
        b.last = Array(UnsafeBufferPointer(start: report, count: len))
    }, Unmanaged.passUnretained(box).toOpaque())
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    let opt = IOOptionBits(seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone)
    let rc = IOHIDDeviceOpen(d, opt)
    if rc != kIOReturnSuccess { print(String(format: "    open rc=0x%08x", rc)) }
}

func send(_ box: Dev, _ payload: [UInt8]) -> (IOReturn, [UInt8]?) {
    box.last = nil
    let rc = payload.withUnsafeBufferPointer {
        IOHIDDeviceSetReport(box.dev, kIOHIDReportTypeOutput, CFIndex(REPORT_ID), $0.baseAddress!, payload.count)
    }
    if rc != kIOReturnSuccess { return (rc, nil) }
    let deadline = Date().addingTimeInterval(0.4)
    while box.last == nil && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    return (rc, box.last)
}

var ok = false
for (ci, box) in devs.enumerated() {
    for len in [63, 64] {
        for i2c in [false, true] {
            let (rc, reply) = send(box, regReadPacket(testRegs[0], i2c: i2c, len: len))
            let tag = "coll#\(ci) len=\(len) \(i2c ? "I2C" : "UART")"
            if rc != kIOReturnSuccess {
                print(String(format: "  %@: setReport rc=0x%08x", tag, rc))
            } else if let r = reply {
                ok = true
                print("  \(tag): reply " + r.prefix(14).map { String(format: "%02x", $0) }.joined(separator: " "))
            } else {
                print("  \(tag): setReport ok, no input report")
            }
        }
    }
}
print(ok ? "\nTRANSPORT OK." : "\nNo input replies. See rc codes above (0xe00002c7 = not permitted/seized elsewhere).")
