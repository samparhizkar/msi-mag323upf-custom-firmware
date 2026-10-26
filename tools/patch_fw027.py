#!/usr/bin/env python3
"""Build a patched MSI MAG 323UPF FW.027 image.

Every patch states the exact original bytes it expects; the script refuses to run
if the input differs, so it can only ever modify the known stock image.

Usage: python3 -I tools/patch_fw027.py [--light-sleep | --093] <stock FW.027 .bin> <output .bin>
  default:       no logo, OSD shows FW.091
  --light-sleep: also always light sleep, OSD shows FW.092
  --093:         FW.092 + User-mode factory defaults + Display P3 EDID, OSD shows FW.093
  --094:         FW.093 without the light-sleep patch (stock deep standby), OSD shows FW.094
  --098:         no logo + P3 EDID + no light sleep, default Pro Mode User; Office & User left stock; OSD FW.098
"""
import hashlib
import struct
import sys

STOCK_SHA256 = "c8720f6bffabdfe5"  # prefix of sha256 of MSI_MAG_323UPF_FW.027_E782.bin
MAIN_PART = 0x108000                # LEON2 Main partition, linked at address 0
MAIN_END = MAIN_PART + 0x167ACC     # end of the last partition; after this is unused 0xFF padding

# (main-partition address, original word, patched word, description)
# The power-on code shows the boot logo only when (settings & 0x5000) == 0x1000.
# Comparing against 0x2000 instead can never match, so every site takes the firmware's
# existing "logo disabled" branch (which also releases the mode-handler hold bit).
NO_LOGO = [
    (0x20600, 0x19000004, 0x19000008, "ShowLogo(): sethi %hi(0x1000),%o4 -> 0x2000"),
    (0x21D5C, 0x1B000004, 0x1B000008, "power-on path A, show-logo test: sethi %hi(0x1000),%o5 -> 0x2000"),
    (0x21D78, 0x11000004, 0x11000008, "power-on path A, release-hold test: sethi %hi(0x1000),%o0 -> 0x2000"),
    (0x21FA4, 0x19000004, 0x19000008, "power-on path B, show-logo test: sethi %hi(0x1000),%o4 -> 0x2000"),
]

# EXPERIMENTAL. Entering standby (power case 3) normally takes the deep path
# (SYSAPI_PowerSaving + hand-off to the 8051) unless state bit 0x800 is set, which
# nothing in FW.027 sets. Removing the branch always takes the dormant light-sleep
# path: panel off, set the suspended flag 0x400; wake is handled by dispatcher action 1.
LIGHT_SLEEP = [
    (0x220B0, 0x0280002B, 0x01000000, "enter standby: be deep_power_saving -> nop (always light sleep)"),
]


# Factory-default settings table (0x198 bytes at main 0x15897c, copied into the settings
# block at 0xa802b878 when the stored settings are invalid or on factory reset). The table's
# validity markers (bytes 0-3 and 0x196-0x197) are left alone, so existing user settings
# survive the flash; the new defaults apply after a factory reset.
DEFAULTS_TABLE = 0x15897C
# FW.098 only changes the default Pro Mode to User; User and every other mode stay stock.
DEFAULTS_098 = [
    (0x141, 0x05, 0x01, "default Pro Mode: sRGB -> User (neutral default; no other changes)"),
]
DEFAULTS = [
    (0x141, 0x05, 0x01, "default Pro Mode: sRGB -> User (0 Eco, 1 User, 2 Anti-Blue, 3 Movie, 4 Office, 5 sRGB)"),
    (0x5D, 0x3C, 0x46, "default User-mode brightness: 60 -> 70 (per-mode table, slot = Pro Mode + 4)"),
]

# EDID store: 36 slots of 0x200 bytes. macOS builds the display profile from the base
# block's chromaticity (bytes 0x19-0x22); set them to Display P3 primaries with a D65 white.
EDID_STORE = (0x118000, 0x11C800)
P3_CHROMA = {"R": (0.680, 0.320), "G": (0.265, 0.690), "B": (0.150, 0.060), "W": (0.3127, 0.3290)}


def encode_chroma(c) -> bytes:
    v = [round(x * 1024) for k in "RGBW" for x in c[k]]   # rx ry gx gy bx by wx wy, 10-bit
    lo1 = (v[0] & 3) << 6 | (v[1] & 3) << 4 | (v[2] & 3) << 2 | (v[3] & 3)
    lo2 = (v[4] & 3) << 6 | (v[5] & 3) << 4 | (v[6] & 3) << 2 | (v[7] & 3)
    return bytes([lo1, lo2] + [x >> 2 for x in v])


MOD_DATE = b"2026-10-24"

# Version labels shown in the OSD ("FW.027", two copies) and the factory menu.
# The new version keeps the leading 0 (hardware line 0XX) and uses digits only.
VERSION_STRINGS = [
    (0x158751, b"FW.027", "OSD version label"),
    (0x158861, b"FW.027", "OSD version label"),
    (0x0DD689, b"FW.027 2024-11-25", "factory menu version + date"),
]


# The version the monitor reports over USB/DDC ("58001<0" -> "5b001<0" + 3 digits, read by MSI
# Gaming Intelligence) is hardcoded in FUN_000500ac as three `or %g0, imm, %oN` instructions,
# separately from the OSD labels. Each entry: (main addr, version digit index).
VERSION_REPLY = [
    (0x500BC, 0),  # or %g0, '0', %o2
    (0x500C0, 1),  # or %g0, '2', %o1
    (0x500B8, 2),  # or %g0, '7', %o0
]
STOCK_REPLY = b"027"


def sum16(b) -> int:
    return sum(b) & 0xFFFF


def main() -> None:
    args = sys.argv[1:]
    patches = list(NO_LOGO)
    version = b"091"
    extras = False
    mbook_defaults = None
    if args and args[0] == "--098":
        version, extras, mbook_defaults = b"098", True, DEFAULTS_098
        args = args[1:]
    elif args and args[0] == "--094":
        version, extras = b"094", True
        args = args[1:]
    elif args and args[0] in ("--light-sleep", "--093"):
        patches += LIGHT_SLEEP
        version = b"092"
        if args[0] == "--093":
            version, extras = b"093", True
        args = args[1:]
    src, dst = args
    img = bytearray(open(src, "rb").read())
    if not hashlib.sha256(img).hexdigest().startswith(STOCK_SHA256):
        sys.exit("input is not the stock FW.027 image")
    stock_sum = sum16(img)

    for addr, old, new, desc in patches:
        off = MAIN_PART + addr
        cur = struct.unpack_from(">I", img, off)[0]
        if cur != old:
            sys.exit(f"{off:#x}: expected {old:08x}, found {cur:08x}")
        struct.pack_into(">I", img, off, new)
        print(f"file {off:#08x} (main {addr:#07x}): {old:08x} -> {new:08x}  {desc}")

    if extras:
        for rel, old, new, desc in (mbook_defaults or DEFAULTS):
            off = MAIN_PART + DEFAULTS_TABLE + rel
            if img[off] != old:
                sys.exit(f"{off:#x}: expected {old:02x}, found {img[off]:02x}")
            img[off] = new
            print(f"file {off:#08x} (defaults +{rel:#05x}): {old:02x} -> {new:02x}  {desc}")

        chroma = encode_chroma(P3_CHROMA)
        slots = 0
        for slot in range(*EDID_STORE, 0x200):
            if img[slot:slot + 8] != b"\x00\xff\xff\xff\xff\xff\xff\x00":
                continue
            if sum(img[slot:slot + 128]) % 256:
                sys.exit(f"EDID slot {slot:#x}: bad checksum before patching")
            img[slot + 0x19:slot + 0x23] = chroma
            img[slot + 127] = (-sum(img[slot:slot + 127])) % 256
            slots += 1
        print(f"EDID: {slots} slots set to Display P3 + D65 ({chroma.hex(' ')}), checksums recomputed")

    for addr, old, desc in VERSION_STRINGS:
        off = MAIN_PART + addr
        if img[off:off + len(old)] != old:
            sys.exit(f"{off:#x}: expected {old!r}")
        new = b"FW." + version + (b" " + MOD_DATE if len(old) > 6 else b"")
        assert len(new) == len(old)
        img[off:off + len(old)] = new
        print(f"file {off:#08x} (main {addr:#07x}): {old.decode()!r} -> {new.decode()!r}  {desc}")

    for addr, idx in VERSION_REPLY:
        off = MAIN_PART + addr
        cur = struct.unpack_from(">I", img, off)[0]
        if cur & 0xFF != STOCK_REPLY[idx] or cur & 0xC1FF_E000 != 0x8010_2000:
            sys.exit(f"{off:#x}: unexpected version-reply instruction {cur:08x}")
        new = (cur & ~0xFF) | version[idx]
        struct.pack_into(">I", img, off, new)
        print(f"file {off:#08x} (main {addr:#07x}): {cur:08x} -> {new:08x}  USB/DDC version digit {idx}")

    # Keep the whole-file 16-bit sum (the suffix in MSI's file name) unchanged by lowering
    # bytes of the unused 0xFF padding after the last partition (equal modulo 0x10000).
    if any(b != 0xFF for b in img[MAIN_END:]):
        sys.exit("padding area is not as expected")
    need = (sum16(img) - stock_sum) & 0xFFFF   # amount the sum must drop
    pad = MAIN_END + 0x10
    while need:
        step = min(need, 0xFF)
        if pad >= len(img):
            sys.exit("not enough padding to compensate the checksum")
        img[pad] -= step
        print(f"file {pad:#08x}: ff -> {img[pad]:02x}  checksum compensation")
        need -= step
        pad += 1

    assert sum16(img) == stock_sum
    open(dst, "wb").write(img)
    print(f"sum16 {sum16(img):#06x} (stock {stock_sum:#06x}), sha256 {hashlib.sha256(img).hexdigest()}")


if __name__ == "__main__":
    main()
