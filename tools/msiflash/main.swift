// msiflash: purpose-built CLI for the MSI MAG 323UPF scaler (Novatek A500/A300, I2C transport).
// Uses the HID transport proven to work on this unit: seize-open the 1462:3FA4 controller, a dedicated
// run-loop thread for input delivery, 64-byte reports with the report ID as byte 0.
//
// Commands:
//   identify              Read model/version/panel/calibration/serial (READ-ONLY, safe).
//   status                Display mode + live monitor state over DDC + identity (READ-ONLY, safe).
//   scaler-id             Query the ISP scaler family ID (A500/A300) and JEDEC flash ID (query, safe).
//   (flash is added after identify/scaler-id are confirmed on this unit)
import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// ---- Transport ----------------------------------------------------------------
final class Controller {
    let dev: IOHIDDevice
    let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    let sem = DispatchSemaphore(value: 0)
    var last: [UInt8]?

    init?() {
        var it: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &it)
        var svc: io_service_t = 0
        while case let s = IOIteratorNext(it), s != 0 {
            func p(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) as? Int }
            if p(kIOHIDVendorIDKey) == 0x1462 && p(kIOHIDProductIDKey) == 0x3FA4 { svc = s; break }
            IOObjectRelease(s)
        }
        guard svc != 0, let d = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else { return nil }
        dev = d
        inBuf.initialize(repeating: 0, count: 256)
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else { return nil }
        IOHIDDeviceRegisterInputReportCallback(dev, inBuf, 256, { ctx, _, _, _, _, r, l in
            let c = Unmanaged<Controller>.fromOpaque(ctx!).takeUnretainedValue()
            c.last = Array(UnsafeBufferPointer(start: r, count: l)); c.sem.signal()
        }, Unmanaged.passUnretained(self).toOpaque())
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            IOHIDDeviceScheduleWithRunLoop(self.dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            ready.signal(); CFRunLoopRun()
        }
        ready.wait()
    }

    /// Send a command (payload = bytes after the report ID). Returns the 64-byte reply (byte 0 = report ID).
    func exchange(_ payload: [UInt8], reportID: UInt8 = 1, timeout: Double = 1.5) -> [UInt8]? {
        last = nil
        var buf = [reportID] + payload
        guard buf.count <= 64 else { return nil }
        while buf.count < 64 { buf.append(0) }
        let rc = buf.withUnsafeBufferPointer { IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), $0.baseAddress!, 64) }
        guard rc == kIOReturnSuccess else { return nil }
        return sem.wait(timeout: .now() + timeout) == .success ? last : nil
    }
}

func xorFold<S: Sequence>(_ b: S) -> UInt8 where S.Element == UInt8 { b.reduce(0) { $0 ^ $1 } }
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

// ---- Normal-mode identity reads (mirror the proven protocol) -------------------
extension Controller {
    func readField(_ command: String, header: String, count: Int, checksum: Bool = false) -> [UInt8]? {
        guard let reply = exchange(Array(command.utf8)) else { return nil }
        let prefix = [UInt8(1)] + Array(header.utf8)
        let end = prefix.count + count
        let terminator = end + (checksum ? 1 : 0)
        guard reply.count >= terminator + 1, Array(reply.prefix(prefix.count)) == prefix,
              reply[terminator] == 0x0D else { return nil }
        let data = Array(reply[prefix.count..<end])
        if checksum, reply[end] != data.reduce(UInt8(0), &+) { return nil }
        return data
    }

    func identify() {
        guard let model = readField("5800140\r", header: "5b00140", count: 3), model.prefix(2) == [0x30, 0x30] else { fail("model read failed") }
        guard let ver = readField("58001<0\r", header: "5b001<0", count: 3) else { fail("version read failed") }
        // panel: header + length byte + name + zero padding (this unit's framing; no CR)
        guard let reply = exchange(Array("58001?0\r".utf8)) else { fail("panel read failed (no reply)") }
        let p = [UInt8(1)] + Array("5b001?0".utf8)
        guard Array(reply.prefix(p.count)) == p else { fail("panel read failed (bad header)") }
        let len = Int(reply[p.count]); let nameStart = p.count + 1; let nameEnd = nameStart + len
        guard len > 0, nameEnd <= reply.count, reply[nameStart..<nameEnd].allSatisfy({ (32...126).contains($0) }) else { fail("panel read failed (bad name)") }
        let panel = String(decoding: reply[nameStart..<nameEnd], as: UTF8.self)
        let cal = readField("580[000\r", header: "5b00[", count: 12, checksum: true) ?? []
        let serial = readField("5800131\r", header: "5b00131", count: 13, checksum: true) ?? []
        print("model:        0x\(String(format: "%02X", model[2]))\(model[2] == 0x94 ? " (MAG 323UPF)" : "")")
        print("version:      \(String(decoding: ver, as: UTF8.self))")
        print("panel:        \(panel)")
        print("calibration:  \(cal.map { String(format: "%02x", $0) }.joined()) \(cal.isEmpty ? "(read/checksum FAILED)" : "(checksum ok)")")
        print("serial:       \(serial.map { b in (32...126).contains(b) ? Character(UnicodeScalar(b)) : "." }.map(String.init).joined()) \(serial.isEmpty ? "(read/checksum FAILED)" : "(checksum ok)")")
        if cal.isEmpty || serial.isEmpty { fail("calibration/serial preservation read failed") }
    }

    /// Query the ISP scaler family ID and JEDEC flash ID (read queries over the I2C tunnel).
    func scalerID() {
        guard let reply = exchange([0xA0, 0x6F, 0, 4, 0x34, 6, 0x36], reportID: 4) else { fail("scaler-id: no reply") }
        // reply: [1][6F][02][.. family ..]; app checks reply[4]==0x6F, reply[5]==2, reply[6] in {A5,A3}, reply[7]==0, xor(reply[4...7])==reply[8]
        let hex = reply.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("scaler-id raw: \(hex)")
        if reply.count > 8, reply[4] == 0x6F, reply[5] == 2, [0xA5, 0xA3].contains(reply[6]), reply[7] == 0, xorFold(reply[4...7]) == reply[8] {
            print("scaler family: A\(String(format: "%X", reply[6]))00  — supported by the proven flash sequence ✓")
        } else {
            print("scaler family: UNRECOGNIZED (reply did not match A500/A300 framing) — do NOT flash with the ported sequence")
        }
    }
}

// ---- Status (read-only): display mode, DDC state, identity -------------------
func printStatus() {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    if let d = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == 0x3669 }), let m = CGDisplayCopyDisplayMode(d) {
        print("display:      \(m.pixelWidth)x\(m.pixelHeight) px, looks like \(m.width)x\(m.height) @ \(Int(m.refreshRate.rounded())) Hz")
    } else {
        print("display:      MSI not connected to this Mac")
        return
    }
    print("link:         rate/lanes not exposed by macOS for USB-C DisplayPort")
    if let svc = externalAVService() {
        let vcps: [(UInt8, String)] = [(0x60, "input source"), (0xD6, "power mode"), (0x10, "brightness"), (0x12, "contrast"), (0x14, "colour preset")]
        for (code, name) in vcps {
            let label = (name + ":").padding(toLength: 14, withPad: " ", startingAt: 0)
            if let (cur, max) = getVCP(svc, code) { print("\(label)\(cur) (max \(max))") } else { print("\(label)no DDC reply") }
        }
    }
    if let c = Controller() { c.identify() } else { print("firmware:     MSI controller busy or not on USB (close MSI apps / check KVM)") }
}

// ---- CLI ----------------------------------------------------------------------
let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "identify"
if cmd == "status" { printStatus(); exit(0) }
guard let c = Controller() else { fail("cannot open MSI controller (1462:3FA4). Close the MSI updater and any monitor-control app, then retry.") }
switch cmd {
case "identify": c.identify()
case "scaler-id": c.scalerID()
case "validate": c.validate()
case "recover": c.recover()
case "diag": c.diag()
default: fail("usage: msiflash [identify|status|scaler-id]")
}

// ---- Stage 1: reversible ISP validation (NO erase, NO flash writes) ----------
extension Controller {
    func xorR(_ s: ArraySlice<UInt8>) -> UInt8 { s.reduce(0) { $0 ^ $1 } }

    // ISP data command on report ID 4: [opcode, 0x6F, 0] + body + xor(body). Validates echo.
    func cmd(_ opcode: UInt8, _ body: [UInt8], delayMs: UInt32 = 5) -> [UInt8]? {
        let payload = [opcode, 0x6F, 0] + body + [xorR(body[...])]
        guard let r = exchange(payload, reportID: 4), r.count >= 10, r[0] == 4, r[1] == opcode, r[2] != 0 else { return nil }
        if delayMs > 0 { usleep(delayMs * 1000) }
        return r
    }
    func writeReg(_ a: UInt16, _ v: UInt8) -> Bool {
        guard let r = cmd(0xA9, [0x6E, 4, 0x78, UInt8(a >> 8), UInt8(a & 0xFF), v]) else { return false }
        return r[6] == 0x87 && xorR(r[4...6]) == r[7]
    }
    func readReg(_ a: UInt16) -> UInt8? {
        guard let r = cmd(0xAA, [0x6E, 3, 0x87, UInt8(a >> 8), UInt8(a & 0xFF)]) else { return nil }
        guard r[6] == 0x78, xorR(r[4...7]) == r[8] else { return nil }
        return r[7]
    }
    func ack(_ payload: [UInt8], delayMs: UInt32) -> Bool {
        guard let r = exchange([payload[0], 0x6F, 0] + payload.dropFirst() + [xorR(payload.dropFirst())], reportID: 4) else { return false }
        usleep(delayMs * 1000); return r.count > 2 && r[0] == 4 && r[1] == payload[0]
    }
    // control command on report ID 1 (SetInterface / ASCII unlock)
    func ctrl(_ bytes: [UInt8]) -> [UInt8]? { exchange(bytes, reportID: 1) }
    func setInterface(_ target: UInt8) -> UInt8? {
        var b = [UInt8](repeating: 0xFF, count: 63); b[0] = 0xE0; b[1] = target
        guard let r = ctrl(b), r.count > 2 else { return nil }
        return r[2]
    }

    func rawCmd(_ reportID: UInt8, _ opcode: UInt8, _ body: [UInt8]) -> String {
        let payload = [opcode, 0x6F, 0] + body + [xorR(body[...])]
        guard let r = exchange(payload, reportID: reportID) else { return "NO REPLY" }
        return r.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    func hex(_ a: [UInt8], _ n: Int = 12) -> String { a.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ") }
    func byteStr(_ b: UInt8?) -> String { b.map { String(format: "0x%02x", $0) } ?? "nil" }
    func diag() {
        print("== diagnostic: enter ISP, try data commands on same handle, all report IDs (raw) ==")
        identifyQuiet("baseline")
        let si0 = setInterface(0); print("enter: SetInterface(0) -> " + byteStr(si0)); usleep(100_000)
        let unlock = ctrl(Array("580040:\r".utf8))
        print("  580040: reply: " + (unlock.map { hex($0, 10) } ?? "NO REPLY"))
        usleep(200_000)
        let si1 = setInterface(1); print("  SetInterface(1) -> " + byteStr(si1)); usleep(2_000_000)
        print("data reads on the SAME handle (raw, no validation):")
        for rid: UInt8 in [4, 2, 1] {
            print("  readReg(0xF049) rid=\(rid) flag=0x6F: " + rawCmd(rid, 0xAA, [0x6E, 3, 0x87, 0xF0, 0x49]))
        }
        // flag=0 variants
        for rid: UInt8 in [4, 2] {
            let nf: [UInt8] = [0xAA, 0, 0, 0x6E, 3, 0x87, 0xF0, 0x49, xorR([0x6E,3,0x87,0xF0,0x49][...])]
            let r = exchange(nf, reportID: rid)
            print("  readReg rid=\(rid) flag=0: " + (r.map { hex($0) } ?? "NO REPLY"))
        }
        // also: does identify still work (handle alive)?
        identifyQuiet("after enter (same handle)")
        print("")
        print("(power-cycle the monitor afterwards to restore normal mode)")
    }
    func recover() {
        print("attempting software recovery (SetInterface 0 + reset)...")
        _ = setInterface(0); usleep(150_000)
        _ = ctrl(Array("580000\r".utf8)); usleep(300_000)
        _ = setInterface(0); usleep(150_000)
        identifyQuiet("after recovery")
    }

    func validate() {
        print("== stage 1: reversible ISP validation (no erase, no writes) ==")
        identifyQuiet("baseline (normal mode)")
        // Enter ISP the MSI way: SetInterface(0), ASCII "580040:\r", SetInterface(1)
        print("entering ISP via MSI command \"580040:\" (report ID 1)...")
        _ = setInterface(0); usleep(100_000)
        _ = ctrl(Array("580040:\r".utf8)); usleep(200_000)
        let si = setInterface(1); usleep(2_000_000)
        print("  SetInterface(1) ack byte: \(si.map { String(format: "0x%02x", $0) } ?? "nil")")
        // Did the MCU stay as 1462:3FA4 (bridge) or drop to bootloader?
        let stillNormal = Controller.present()
        print("  MCU still enumerated as MSI Gaming Controller (1462:3FA4): \(stillNormal ? "YES ✓ (did NOT trip bootloader)" : "NO — dropped off / bootloader")")
        guard stillNormal else { print("\nRESULT: MSI enter command also drops this MCU. Power-cycle to recover."); return }
        // Try an ISP data read (report ID 4) to confirm bridge control
        print("testing ISP data channel (report ID 4)...")
        // reference init (minus the A0 identify that tripped our bootloader)
        _ = writeReg(0xF0E0, 0xAA); _ = writeReg(0xF0E2, 0xAA)
        if let mode = readReg(0xF049) { print("  F049 read ok -> mode 0x\(String(format: "%02x", mode & 0x0F))"); _ = writeReg(0xF055, mode & 0x0F) }
        else { print("  F049 read: NO RESPONSE (data channel not active)") }
        // mailbox + register setup
        for selector: UInt8 in [2, 0x12] {
            _ = ack([0xBC, 0, 0, 0xB0, 0xFF, 0x3D], delayMs: 1)
            _ = ack([0xBE, 0, 0, 0xB0, 0x80, 8, 0, selector, 0x9F, 0, 0x10, 0, 0], delayMs: 1)
            _ = ack([0xBC, 0, 0, 0xB0, 0x8C, 0x80], delayMs: 1)
        }
        for (a, v): (UInt16, UInt8) in [(0xF1DF,0x80),(0xF1A8,2),(0xF0E0,0xAA),(0xF0E2,0xAA),(0xF068,0x9F),(0xF067,0x20),(0xF0E5,0x40),(0xF0E5,0),(0xF0E6,4),(0xF04E,0),(0xD909,0x55),(0xD90A,0x55),(0xD906,4),(0xD905,3),(0xD904,0xFE),(0xD90B,0x84),(0xD90C,0x30),(0xF04C,0x60),(0xD929,6)] { _ = writeReg(a, v) }
        usleep(500_000)
        // read JEDEC flash ID
        _ = writeReg(0xF0C0, 0x13)
        if configureSeq([0x9F], count: 3), executeSeq() {
            var s: [UInt8] = []; for off in 0..<16 { s.append(readReg(0xA700 + UInt16(off)) ?? 0) }
            let jedec = Array(s[3...5])
            print("  JEDEC flash ID: \(jedec.map { String(format: "%02x", $0) }.joined(separator: " "))")
            let mfg = ["c8": "GigaDevice", "ef": "Winbond"][String(format: "%02x", jedec[0])] ?? "?"
            let cap = jedec.count > 2 ? (1 << Int(jedec[2])) : 0
            print("  -> \(mfg), \(cap >> 20) MiB, type 0x\(String(format: "%02x", jedec.count>1 ? jedec[1] : 0))")
            if jedec[1] == 0x40, [0xC8,0xEF].contains(jedec[0]) { print("  FLASH SUPPORTED ✓ — full control path works in ISP mode") }
        } else { print("  JEDEC read: sequence failed") }
        // Exit ISP (best effort; power-cut is the guaranteed backstop)
        print("exiting ISP...")
        _ = exchange([0xA1, 0x6F, 0, 0x34, 6, 0x3c, xorR([0x34,6,0x3c][...])], reportID: 4)
        usleep(200_000); _ = setInterface(0); usleep(100_000)
        _ = ctrl(Array("580000\r".utf8)); usleep(500_000)
        let back = Controller.present()
        print("  back to normal controller: \(back ? "YES" : "no — power-cycle the monitor to restore")")
        if back { identifyQuiet("after exit") }
    }

    func configureSeq(_ spi: [UInt8], count: Int) -> Bool {
        let body = [UInt8(spi.count), UInt8(count)] + spi
        for (a, v): (UInt16, UInt8) in [(0xF0C1,0xA7),(0xF0C2,0),(0xF0C3,0xA7),(0xF0C4,2),(0xF0C5,0xA7),(0xF0C6,UInt8(body.count))] { if !writeReg(a, v) { return false } }
        for (o, v) in body.enumerated() { if !writeReg(0xA700 + UInt16(o), v) { return false } }
        return true
    }
    func executeSeq() -> Bool {
        guard let r = cmd(0xAF, [0x6E, 1, 0x25], delayMs: 100) else { return false }
        usleep(200_000); return r[6] == 0xDA && xorR(r[4...6]) == r[7]
    }
    func identifyQuiet(_ label: String) {
        let m = readField("5800140\r", header: "5b00140", count: 3)
        print("  [\(label)] model: \(m.map { String(format: "0x%02x", $0[2]) } ?? "NO READ")")
    }
    static func present() -> Bool {
        var it: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &it)
        var found = false
        while case let s = IOIteratorNext(it), s != 0 {
            func p(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()) as? Int }
            if p(kIOHIDVendorIDKey) == 0x1462 && p(kIOHIDProductIDKey) == 0x3FA4 { found = true }
            IOObjectRelease(s)
        }
        return found
    }
}
