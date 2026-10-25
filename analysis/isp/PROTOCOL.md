# MSI MAG 323UPF firmware-flash protocol (NT68500 over USB HID)

Reverse-engineered from MSI Gaming Intelligence (`FWUpdaterDll.dll` + `MSIISPDll.dll`,
decompiled). This is what the Windows updater does when it flashes the scaler. Documented so a
macOS flasher can reproduce it exactly.

## Transport

- USB HID device **VID 0x1462, PID 0x3FA4** ("MSI Gaming Controller"). On macOS it enumerates with
  two HID collections, 64-byte in/out reports, usage page 1 / usage 0. Access needs no entitlement
  (unlike *creating* a virtual HID device).
- Windows uses overlapped `WriteFile`/`ReadFile` on the HID handle, 64-byte buffers, **report ID 1**
  as byte 0. A global mutex `"USB_HID"` serialises access.
  - macOS equivalent: `IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 1, payload, 63)` and
    `IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, 1, buf, 63)`, or an input-report callback.
    (Probe empirically whether the report ID is separate or in-band; maxReport=64 suggests 1 ID + 63.)
- Write wrapper (`FUN_103fb3a0`): buf[0]=reportID 1, buf[1..]=payload (≤63), send 64 bytes.
- Read wrapper (`FUN_103f2c80`): read 64 bytes, strip leading report-ID byte.
- Full transaction (`FUN_103f5600`): write one 64-byte packet; optional `Sleep(ms)`; optional read
  back one 64-byte packet into the same buffer.

## DDC/CI framing inside the tunnel

Most commands carry a DDC/CI message to the scaler at slave **0x6E**. Packet layout in the HID payload:

```
[0] HID command byte   (0xA5/0xA6/0xA7 program, 0xB5 page-checksum, 0xA9 reg-write, 0xAA reg-read, 0xE0 set-interface)
[1] interface flag     ('o'=0x6F when I2C bridge active, else 0 — set from DAT_10c00112)
[2] 0x6E               DDC/CI destination
[3] length             DDC data length
[4] sub-command        (0x78 reg-write, 0x87 reg-read, 0x36 page-checksum, 0x3C program-start, …)
[5..] args
[last] XOR checksum of bytes [2..last-1]  (FUN_103e7f10 = XOR fold)
```

Responses are validated by DDC source byte: 0xC9 (reg-read 0xAA), 0xC3 (program final 0xA7),
0x37-ish for page-checksum, plus a trailing XOR check.

## Commands

| Cmd | Name | Payload | Returns |
|-----|------|---------|---------|
| 0xE0 | SetInterface | `[0xE0, target, 0xFF…]` write+read; `[1]` of reply = active interface | 0=UART, 1=I2C |
| 0xA9 | RegWrite | `[0xA9,fl,0x6E,0x04,0x78, aH,aL, val, xor]` | ack |
| 0xAA | RegRead  | `[0xAA,fl,0x6E,0x03,0x87, aH,aL, xor]` → reply val at [+?] | reg value |
| 0xB5 | PageChecksum | `[0xB5,fl,0x6E,0x04,0x36, a23_16,a15_8,0x00, xor]`, addr=page<<9 | u16 sum of 512 bytes |
| 0xA5 | ProgStart | `[0xA5,fl,0x6E,0x00,0x3C, page, 0xF0,0x0F,0x6E,0x91,0x13,0xEC, <50 data>, xor]` write-only | — |
| 0xA6 | ProgChunk | `[0xA6, <60 data>, xor]` ×7, write-only, XOR accumulates in running sum | — |
| 0xA7 | ProgEnd   | `[0xA7, <42 data>, running_xor]` write+read, verified by src 0xC3 | ack |

Register fallback IDs (ISP-enter dance in `_EnableISP` for NT68500):
`RegWrite 0xF0E0←0xAA`, `RegWrite 0xF0E2←0xAA`, `RegRead 0xF049` (expect low nibble ≤7),
`RegWrite 0xF055←nibble`, plus the unlock string sent as a raw packet beginning
`35 38 30 30 34 30 3A 0D` = ASCII **"580040:\r"**.

## Flash geometry

- Page = **512 bytes** (0x200). Image = whole .bin (≈2.5 MB → ~5000 pages).
- Program loop (`_ScalerProgram`): for each page from `start`:
  1. compute `sum16` of the 512 file bytes; `blank` = all 0xFF
  2. if not blank: `ProgStart(0xA5, first 50 bytes)`, `ProgChunk(0xA6)×7 (60 bytes each)`, `ProgEnd(0xA7, last 42 bytes)` — 50+420+42 = 512
  3. if not blank: `PageChecksum(0xB5)` read-back, compare to computed `sum16`; **abort page on mismatch**
  - blank (all-0xFF) pages are skipped entirely.
- `DualFwEnable=true` for 323UPF: `DAT_10c00104`/`DAT_10c00100` split the image into two halves
  (dual-FW banks); the program loop covers `[DAT_10c00104, DAT_10c00100+DAT_10c00104)`.

## Full sequence (`UpdateFWWithCheckInterface`)

1. **CheckFileCorrent**: image must contain marker `55 AA 66 99 "UART" <modelIndex>` where
   `modelIndex = 100 + 48 = 0x94` for 323UPF (present in our .bin at 0x2607b8), and `55 AA 66 99 "PANEL"
   <len> "AUO M320QAN02.9"`.
2. **SetInterface** → I2C (target 1) for 323UPF (DeviceInterfaceType.I2C in DeviceFactory).
3. **EnableISP** (isBackup=true, backupSel=0xC0, setting): backs up EDID/colour-temp to files,
   sends unlock string + ISP-enter register writes, `Sleep(2000)`.
4. **EEPROM_WP**: handle EEPROM write-protect using the `Flash_Def` descriptor (flash ID/erase opcodes).
5. **ScalerErase**: chip/sector erase per `Flash_Def` (SE/BE codes); writes a zeroed 0x3F-byte block
   and verifies its checksum first.
6. **ScalerProgram**: the page loop above.
7. **DisableISP** (delay 30000 ms): leave ISP, restore EDID/colour backup, reset scaler.

`Flash_Def` (from Nuvoton_NT68500_I2C.cs, marshalled struct): En, ID1-3, FE2P, ByteWrite, SE_Code,
BE32K_Code, BE64K_Code, CE_Code, Page(u32), SE_Time, BE32K/BE64K timeouts, CE_Time, Name[46]. The
flash descriptor is read from the chip during EnableISP (`_GetID`) and from `PlugIn/Flash.dat`.

## macOS implementation notes

- `tools/isp-probe` (read-only): opens the HID device, does RegRead of benign status regs and a
  couple of PageChecksum reads. No ISP, no writes. Validates transport + framing on real hardware.
- A flasher must replicate steps 1-7 exactly, including the `Flash_Def` erase opcodes and timing.
  The per-page checksum read-back is the main safety net (same as the Windows tool), but a bug in the
  ISP-enter / erase / EEPROM-WP / disable steps can brick the scaler with no software recovery.

## macOS bring-up status (2026-10-24)

- Target HID confirmed: 1 interface (class 3 HID, 2 endpoints = interrupt IN + OUT), report ID 1,
  63-byte in/out reports (descriptor `0501 0900 a101 8501 1500 25ff 1901 2908 953f 7508 8102 …`).
  Framing/report-ID/length all match the Windows wrappers.
- `IOHIDDeviceSetReport(output, reportID 1, 63 bytes)` **succeeds (rc=0)** for SetInterface(0xE0) and
  RegRead(0xAA) — the write path works from macOS with no entitlement.
- **Open problem:** no input-report ever arrives via `IOHIDDeviceRegisterInputReportCallback`
  (tried default + seized open, UART+I2C flags, 63 and 64-byte payloads, F049/F000/C9C9).
  So two-way comms isn't established yet. The device accepts commands but we see no reply.
- Likely next step: the generic HID driver (usage page 1 / usage 0) may not surface these vendor
  input reports to user space, or macOS routes the OUT report via control SET_REPORT while the
  firmware only acts on interrupt-OUT. Resolving this probably needs raw endpoint I/O via
  `IOUSBHostInterface` (claim interface #0 away from AppleUserHIDDevice, then interrupt IN/OUT
  pipes directly). That is a larger piece of work.
- Tools: `tools/isp-probe/` (read-only register-read probe). Read-only; never enters ISP.

## SOLVED: existing native macOS updater (2026-10-24)

A native, MIT-licensed macOS updater already exists and **lists the MAG 323UPF as a supported model**:
danielheimburg/msi-monitor-updater. It flashes over USB-C from the Mac (demonstrated on MEG 342C;
323UPF profile present but inferred/not hardware-tested by its author).

Why my from-scratch probe got no replies (now understood from its source):
- Input reports are delivered reliably only from a **dedicated thread running `CFRunLoopRun()`**
  with the device scheduled on that loop — not by pumping the run loop on the main thread between
  sends (their comment: "passed the read sweep that failed under dispatch delivery").
- The command encoding is **ASCII command strings**, not the raw binary DDC 0xAA/0x87 I guessed:
  e.g. identify = send `"5800140\r"` (report ID 1), expect reply header `"5b00140"` + 3 bytes;
  version = `"58001<0\r"` → `"5b001<0"`. These are the `5800xxx`/`5b00xxx` templates seen in the FW.
- Raw USB endpoint access is impossible anyway: the kernel HID driver holds interface #0 exclusively
  (`USBInterfaceOpen` and even `OpenSeize` → 0xe00002c5).

Our custom FW.093 passes that app's validation (verified):
- `SHA256(first 0x6000)` == `0aa25302…` (branch-0 loader digest) — all our patches are above 0x6000.
- Model marker `55AA6699 "UART"` unique, modelCode +8 = 0x94; version records "FW.093"; panel
  "AUO M320QAN02.9" intact. No whole-file hash is required.

So the app can flash both stock MSI firmware and our FW.091/092/093 on the Mac. Caveats: preview,
unnotarized, 323UPF profile inferred; flash stock 027 first as an end-to-end test; close MonitorControl
and any DDC brightness app (e.g. MonitorControl) during flashing.

## Patched updater for the 323UPF controller (2026-10-24)
The upstream app rejected this unit: "unsupported HID identity." Cause: its MonitorDevice.discover()
exact-matches the HID report descriptor against two known strings, and this 323UPF's MCU revision
reports a THIRD variant — reports 1-4 byte-identical to the app's legacyReportDescriptor, but omitting
the trailing unused vendor (0xFF00) collection (the app author's own comment: reports 1-4 are "the same
64-byte contract; the extra report 3 and feature 72 are unused").
Fix: added this unit's descriptor (05010900a101 8501.. 8502.. 8503.. 8504.. ..9102 c0) to the accepted
list and rebuilt. Output: "MSI Firmware Updater (patched-323UPF).app" in the project root.
Safety: the app reads identity, re-reads and requires a match, and preserves calibration/serial BEFORE
enterISP/erase — so if the transport does not actually work on this unit it aborts at identity read,
before any flash write. Instruction to user: if it reads identity (MAG 323UPF + version) proceed;
if identity read fails, STOP. Flash stock 027 first.

## CRITICAL finding: USB controller drops off on ISP entry (2026-10-25)
- Standalone CLI (tools/msiflash) reads the FULL normal-mode identity on this unit: model 0x94,
  version 027, panel AUO M320QAN02.9, calibration + serial (checksums valid). Transport PROVEN.
- But the scaler-ID ISP query (A0 6F 00 04 34 06 36 on report ID 4) caused the "MSI Gaming Controller"
  USB device to DROP OFF THE BUS and it did NOT re-enumerate on its own (>24s). Monitor video/DDC
  stayed fully alive (not bricked). Nothing was erased/programmed (query is before any flash write).
- This matches the reference docs: the A0 identity command RE-ENTERS ISP, and "the tested I2C path
  reconnects USB." On I2C models the controller drops USB during ISP by design and must reconnect.
  On THIS unit it did not reconnect cleanly, and the simple CLI has no reopen logic.
- Implication: native macOS flashing is risky on this specific unit — if USB drops mid-flash (after
  erase, before program completes) and does not cleanly reconnect, the scaler could be left half-written
  = brick. MSI's Windows tool flashed FW.092 here successfully, so it handles this controller's USB
  behavior; that (via a Windows VM with USB passthrough, or a laptop) remains the reliable route.
- Recovery: USB-C replug, or power-cycle the monitor (off 10s, on) to reset the controller to normal
  mode. Decision: stop native flash development; do not keep sending ISP commands to this controller.

## MSI's PROVEN I2C enter/exit-ISP (from MSIISPDll_NT68500_I2C.dll, 2026-10-25)
- The 323UPF DLL opens 1462:3FA4 (pushed 26x); 0x3F00 is never pushed. All control writes use the
  write wrapper that sets buf[4]=1 → REPORT ID 1 (not report ID 4 as the reference app assumed).
- Enter-ISP sequence (_EnableISP): SetInterface(0) query loop → send ASCII "580040:\r"
  (35 38 30 30 34 30 3A 0D) on report ID 1 → Sleep 200 → SetInterface(1) loop until ack → Sleep 2000.
- This is the command that successfully flashed FW.092. The reference app's I2C identify
  [A0 6F 00 04 34 06 36] on report ID 4 is a DIFFERENT command that trips THIS MCU's Nuvoton bootloader
  (re-enumerates as 0416:3F00 "Nuvoton ISP"; recover with a full power cut, not a soft power-cycle).
- Exit-ISP (_DisableISP): FUN_103e6dc0 + Sleep → SetInterface(0) → FUN_103f1b80 (reset) → restore.
- Register/program data commands (0xAA/0xA9/0xB5/0xA5/0xA6/0xA7) go through the other write wrapper
  on report ID 2/4 (interface-dependent). Full byte-level framing in i2c_enterisp.c / i2c_flashops.c.

## Decision point
Native flashing is now plausible using MSI's proven commands (my transport already does report-ID-1
ASCII commands - identify works). But a full flasher = faithfully porting enter-ISP, JEDEC read,
EEPROM-WP, erase, program+verify, exit-ISP, calibration/serial restore. Large + brick-risk; a mid-erase
failure is unrecoverable without a hardware SPI programmer. Safe path if proceeding: a REVERSIBLE
validation first (enter ISP -> read scaler ID + JEDEC flash ID -> exit ISP cleanly), NO erase/program,
to prove the full control path on this MCU before anything destructive.

## Stage 1 validation result (2026-10-25)
POSITIVE: MSI's enter command "580040:\r" (report ID 1) + SetInterface(1)=ack 0x01 keeps the MCU
alive as 1462:3FA4 — it does NOT trip the Nuvoton bootloader (unlike the reference app's A0 on
report ID 4). So the enter path is correct and safe on this unit.
BLOCKER: after entering ISP, the ISP data commands on report ID 4 (0xAA/0xA9/JEDEC, the format that
works on the MEG 342C) got NO response. So we can enter ISP but not yet talk to the scaler/flash.
The MCU then stuck (enumerated, unresponsive to identity); software SetInterface(0)+reset did not
restore it — needs a full power-cut.
LIKELY CAUSES (to investigate SAFELY via decompile, no device risk): (a) data-command report ID on
this MCU may be 2 not 4 (MSIISPDll uses DAT_10c00112-dependent 2/4); (b) MSI's _EnableISP may run an
essential setup step (FUN_103e59e0) after "580040:" before data commands activate, which stage 1 skipped.
NEXT: decompile MSIISPDll data-command path for the exact report ID and the post-enter setup, then retry.

## DECISIVE diagnostic result (2026-10-25)
Enter ISP ("580040:\r" rid1 -> SetInterface(1)=0x01), then register read 0xAA on the same handle:
- rid=4: REPLY "04 aa 01 00 6f 00 00 00..." (HID tunnel to the MCU WORKS, report ID 4 confirmed).
- rid=2, rid=1: NO REPLY.
- BUT the DDC/scaler read returned empty: reply[6]=0x00 (reference expects 0x78 ack) and value=0x00.
  So the MCU HID tunnel responds, but the SCALER does not return ISP register data.
- "580040:" unlock itself returned NO REPLY.
CONCLUSION: we can talk to the MCU (transport fully proven) but cannot get the scaler to respond in
ISP mode. The remaining gap (exact scaler unlock/handshake/framing/timing, possibly a two-phase read
or a device re-enumeration + reopen that MSI's tool does) cannot be nailed by black-box poking without
capturing MSI's Windows tool USB traffic (Wireshark + USBPcap on one real flash). Stopping native-flash
trial-and-error here. For a future attempt, a USB capture would give the exact sequence to finish a
native flasher. Normal-mode reads (identify/calibration/serial) work perfectly on macOS (tools/msiflash).
