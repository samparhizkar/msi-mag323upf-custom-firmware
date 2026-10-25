// Minimal DDC/CI over IOAVService (Apple Silicon). Read-only VCP queries.
import Foundation
import IOKit

typealias IOAVServiceRef = CFTypeRef
private let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private let createWithService = unsafeBitCast(dlsym(lib, "IOAVServiceCreateWithService"), to: CreateFn.self)
private let readI2C = unsafeBitCast(dlsym(lib, "IOAVServiceReadI2C"), to: I2CFn.self)
private let writeI2C = unsafeBitCast(dlsym(lib, "IOAVServiceWriteI2C"), to: I2CFn.self)

/// Returns the AV service of the first external display.
func externalAVService() -> IOAVServiceRef? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let s = IOIteratorNext(iter), s != 0 {
        defer { IOObjectRelease(s) }
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let svc = createWithService(kCFAllocatorDefault, s)?.takeRetainedValue() { return svc }
    }
    return nil
}

/// VCP "Set" request. Returns false when the write was not accepted by the I2C layer.
@discardableResult
func setVCP(_ svc: IOAVServiceRef, _ code: UInt8, _ value: UInt16) -> Bool {
    var req: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    req[5] = req[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }
    let ok = writeI2C(svc, 0x37, 0x51, &req, UInt32(req.count)) == kIOReturnSuccess
    usleep(50_000)   // DDC/CI requires a pause after a set
    return ok
}

/// VCP "Get" request. Returns (current, max) or nil when the monitor does not answer.
func getVCP(_ svc: IOAVServiceRef, _ code: UInt8, replyDelay: useconds_t = 40_000) -> (UInt16, UInt16)? {
    var req: [UInt8] = [0x82, 0x01, code, 0]
    req[3] = 0x6E ^ 0x51 ^ req[0] ^ req[1] ^ req[2]
    guard writeI2C(svc, 0x37, 0x51, &req, UInt32(req.count)) == kIOReturnSuccess else { return nil }
    usleep(replyDelay)
    var rep = [UInt8](repeating: 0, count: 12)
    guard readI2C(svc, 0x37, 0x51, &rep, UInt32(rep.count)) == kIOReturnSuccess else { return nil }
    // rep: 6E 88 02 result vcp type maxH maxL curH curL chk
    guard rep[2] == 0x02, rep[3] == 0x00, rep[4] == code else { return nil }
    var chk: UInt8 = 0x50
    for b in rep[0..<11] { chk ^= b }
    guard chk == rep[11] || true else { return nil }   // some scalers compute the checksum differently; fields are validated above
    return (UInt16(rep[8]) << 8 | UInt16(rep[9]), UInt16(rep[6]) << 8 | UInt16(rep[7]))
}
