// ddcprobe: read VCP codes once (read-only). Usage: ddcprobe [hex codes...]
import Foundation

guard let svc = externalAVService() else { print("no external AV service"); exit(1) }
let names: [UInt8: String] = [0xD6: "power mode", 0x10: "brightness", 0x12: "contrast", 0x14: "color preset",
                              0x16: "red gain", 0x18: "green gain", 0x1A: "blue gain", 0x60: "input source",
                              0xDC: "display mode", 0x0C: "color temp", 0xC9: "fw level", 0xDF: "VCP version"]
let codes: [UInt8] = CommandLine.arguments.count > 1
    ? CommandLine.arguments.dropFirst().compactMap { UInt8($0, radix: 16) }
    : [0xD6, 0x10, 0x12, 0x14, 0x60, 0xC9, 0xDF]
for code in codes {
    var r: (UInt16, UInt16)? = nil
    for _ in 0..<3 where r == nil { r = getVCP(svc, code); if r == nil { usleep(50_000) } }
    print(String(format: "VCP %02X %-13@ ", code, (names[code] ?? "?") as NSString) + (r.map { "cur=\($0.0) max=\($0.1)" } ?? "no reply"))
    usleep(50_000)
}
