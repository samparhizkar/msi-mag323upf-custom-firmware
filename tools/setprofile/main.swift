// setprofile: show or set the ColorSync profile of the MSI display.
// Usage: setprofile            -> print the current profile
//        setprofile <icc path> -> assign that profile
//        setprofile --reset    -> go back to the default (EDID-derived) profile
import ApplicationServices
import ColorSync
import Foundation

let msiVendor: UInt32 = 0x3669

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
guard let display = ids.prefix(Int(n)).first(where: { CGDisplayVendorNumber($0) == msiVendor }),
      let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {
    print("MSI display not found"); exit(1)
}

func currentProfile() -> String {
    guard let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
        .takeRetainedValue() as? [String: Any],
          let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any],
          let defaultID = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String
    else { return "?" }
    let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any]
    if let url = custom?[defaultID] as? URL { return "custom: \(url.path)" }
    if let entry = factory[defaultID] as? [String: Any],
       let url = entry[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL { return "factory: \(url.path)" }
    return "factory (built-in)"
}

let args = CommandLine.arguments
if args.count == 1 { print(currentProfile()); exit(0) }

let profileID = kColorSyncDeviceDefaultProfileID.takeUnretainedValue()
let value: Any = args[1] == "--reset" ? kCFNull! : URL(fileURLWithPath: args[1]) as CFURL
let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid,
                                          [profileID: value] as CFDictionary)
print(ok ? "set. now: \(currentProfile())" : "failed")
