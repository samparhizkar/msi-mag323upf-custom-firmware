# MSI MAG 323UPF firmware notes

Monitor: MSI MAG 323UPF, installed FW.027, AUO M320QAN02.9 panel. Mac connects over Type-C (DP alt mode), 3840x2160 @120 Hz.

## Images
| file | line | chip | notes |
|---|---|---|---|
| MSI_MAG_323UPF_FW.027_E782.bin | 0XX | NT68501 | matches the installed firmware; base for any patch |
| MSI_MAG_323UPF_FW.107_CFA3.bin | 1XX | NT68503 | other silicon; ideas only, no code transplant |
| MSI_MAG_322UPF_FW.017/107 | | | different model (322UPF), not for this monitor |

The filename suffix is the 16-bit byte sum of the whole file (e.g. sum(027) & 0xFFFF = 0xE782).

## SoC
Novatek NT68500 family: 8051 boot MCU, 2x LEON2 SPARC V8 (Main, Sub), Tensilica DSP, DDR3.

## FW.027 layout
Partition table at 0x6000, big-endian (offset, size) pairs:

| offset | size | content |
|---|---|---|
| 0x010000 | 0xF8FF | 8051 code |
| 0x020000 | 0xE552 | 8051 code |
| 0x030000 | 0xE588 | Tensilica DSP |
| 0x050000 | 0x51F90 | LEON2 Sub, linked at 0xA0060000 (reset handler 0xA00602C0) |
| 0x0A6000 | 0x1478 | ? |
| 0x0B0000 | 0x1D2C4 | ? |
| 0x0D0000 | 0x76B0 | LEON2 loader (trap table; reset handler 0xA0029000) |
| 0x0EC000 | 0x56A0 | resource directory (addr, size, flags records) |
| 0x108000 | 0x167ACC | Main partition: EDID store at 0x118000, code from about 0x128000 |

The LEON2 Main load base is not resolved yet; string-pointer matching gives two candidates, 0xA7DBC000 and 0xA7E46000.

## Wake-path strings to chase
MODE_WAITPANELREADY, MODE_WAITPANELREADY_2nd, MDHDLRs[%d].bDisplayDelay, APPTasksBeforeDisplay*,
GlobalModeHandler : Tigger to display, "wakeup from susped DPMS", Auto Scan.

## Measurements (2026-10-24)
- macOS marks the display awake 7-13 ms after the wake request.
- The monitor answers DDC within about 45 ms.
- VCP D6 always reads 1, even in standby, so DDC can't show the real picture-on time; that needs an optical measurement.
- DDC readout: brightness 0/100, contrast 70, colour preset 0x05 (6500 K), input 0x10 (Type-C).

Tools: tools/wakebench (sleep/wake timing plus DDC polling), tools/ddcprobe (one-shot VCP reads).

## Main code (resolved)
- The LEON2 Main partition is linked at address 0 relative to its start: address = file offset - 0x108000. RAM variables are at 0xA802xxxx, hardware registers at 0xCFxxxxxx, and SRAM routines at 0xA002xxxx (the 0xD0000 partition).
- Ghidra project: language `sparc:BE:32:default`, base 0. Decompiled extracts are in analysis/decomp/.
- 0x7651c printf (debug log); 0x256f4 timer_set(id, ms), 19 software timers.
- 0x244b4 APPActionDispatcher: Key/OSD/DDC-CI/APP events map to 63 actions via the jump table at 0x255a4. Action 1 = wake from DPMS.
- 0x21ba8 power-state machine: 0 = power button (dc on/off), 2 = AC power-on, 3 = enter power saving, 5 = wake from power saving -> 0x2582c(3).
- 0xbdbe0 per-input mode handler: MODESEARCH -> CAPTURE -> DISPLAY 0-5 -> WAIT2SHOW -> WAITPANELREADY -> FRC lock -> WAITPANELREADY_2nd. Mode-handler flag bit 0x2000000 means "hold, don't display".
- The logo is only shown on power-on (cases 0 and 2), never on wake from sleep. It sets the hold bit on every input (0xbcf78) and arms timer 3 for 3000 ms.
- The hidden factory menu (strings at 0xdd5xx) has no logo toggle.

## Integrity
- No partition CRC32 or sum32 is stored in the image, and FW.027 has no trailer. The only known check is the whole-file sum16 in the filename.
- The 322UPF FW.017 image does carry a trailer; not investigated.

## Patch 1: no boot logo (tools/patch_fw027.py -> patched/MSI_MAG_323UPF_FW.027_E782.bin)
- Four `sethi %hi(0x1000)` -> `sethi %hi(0x2000)` at main 0x20600, 0x21d5c, 0x21d78 and 0x21fa4, so the test "(settings & 0x5000) == 0x1000" never matches and every site takes the existing no-logo branch.
- One padding byte at file 0x26fadc (FF -> EF) keeps sum16 at 0xE782.
- Patched image sha256: 740c349c37f802bce04977c31a4ab750304282d2f65d900d7c5fd06b475a2bc8
- Expected effect: about 3 s faster cold power-on. No effect on wake from sleep.
- Status: built and statically verified. NOT flashed.

## Still to do (wake from sleep)
- Measure the baseline optically.
- Trace 0x2582c(3) and the mode-search stability debounce.
- Find the panel power-on sequence (SRAM code 0xa002e160 and 0x9ef70) and the timers armed in dispatcher actions (1000 ms timer 1 after power actions 4/62; 5000 ms timers 4/5/6/7).

## Wake-from-sleep findings (best effort, no optical baseline)
- Entering standby is power case 3. Normally it runs SYSAPI_PowerSaving (0xc4a8c): it powers down the input PHYs and scaler blocks and hands control to the 8051, which watches for "mrx wake up" or a wakeup timer. This deep standby and its restore is the most likely main cost of waking.
- The 0x2582c setters (500 / 50 / 2000 ms at 0xa802401e / 401c / 401a) are front-panel key repeat timings, not wake timings. c80f0(5000) is probably the no-signal timeout.
- 0x77e6c (mode-handler state 6) is a PLL lock poll: about 51 ticks, up to 6 retries. That's real hardware settling; leave it alone.
- Case 3 has a dormant light-sleep branch at main 0x220a8 (`andcc state,0x800; be deep`): panel off only, everything else stays powered. Nothing in FW.027 sets bit 0x800.
- Correction: the light-sleep path sets suspended flag 0x400 (word 0xa802b6c8), and dispatcher action 1 ("wakeup from susped DPMS", APP event 0x03) resumes exactly when that flag is set. Deep standby never sets 0x400. So action 1 is the light-sleep wake handler. Event 0x03 is posted with a computed value, so its source isn't statically confirmed.

## Patch 2 (EXPERIMENTAL): always light sleep
- tools/patch_fw027.py --light-sleep -> patched/experimental-light-sleep/MSI_MAG_323UPF_FW.027_E782.bin (includes the no-logo patch).
- main 0x220b0: `be 0x2215c` (0280002B) -> nop (01000000).
- Checksum compensated in the trailing padding (259 bytes lowered); sum16 is still 0xE782.
- sha256 126dddde16bf6e7e98046e4e7a1692e6d75b91a00ff218aed7c3c92e31452815
- Expected: much faster wake (inputs, DDR and CPUs stay powered; only the panel is off), but higher standby power.
- Risk: the path is dormant in this build. If the wake event doesn't fire, the screen stays dark until the power button is pressed (case 0 path). That's recoverable; flash stock or Patch 1 afterwards.
- Full decompile of Main: the scratchpad has main027_all.c (2,395 functions).

## Version labels (both images)
- OSD labels "FW.027" (main 0x158751 and 0x158861) and the factory string "FW.027 2024-11-25" (main 0xdd689) are rewritten at the same length.
- patched/MSI_MAG_323UPF_FW.091_E782.bin: no logo, OSD shows FW.091. sha256 5aedd953a898157ce92ce6761697c0ec162f0b093e5611108bc5935667163af7
- patched/experimental-light-sleep/MSI_MAG_323UPF_FW.092_E782.bin: no logo + light sleep, OSD shows FW.092. sha256 83eb84abc6f78429cdc19a3702e189c88928de74257c59b68c9951945dfc772d
- The earlier hashes for patch 1 (740c...) and patch 2 (126d...) are superseded.

## Flash results (2026-10-24)
- The user flashed FW.091 and FW.092 with MSI Gaming OSD on Windows: both installed and run. MSI's updater accepts modified images whose sum16 matches the filename.

## Mac colour setup (2026-10-24)
- This model's Pro Modes are Eco, User, Anti-Blue, Movie, Office and sRGB. Display P3, Adobe RGB and Calibration 1-3 exist only as strings.
- Final setup: Pro Mode User; colour preset 6500 K (VCP 14 = 5); RGB gains 50/50/50; brightness 70, contrast 70; macOS keeps its EDID-derived profile; HDR off.
- Eco mode reports brightness 0 over DDC. Writing any RGB gain switches the preset to User (VCP 14 = 7), which looked washed out at 50/50/50.
- The user found manual white matching confusing; we went with the factory 6500 K white instead.
- MonitorControl is installed via Homebrew for brightness keys and the slider.

## FW.093 (tools/patch_fw027.py --093 -> patched/fw093/MSI_MAG_323UPF_FW.093_E782.bin)
- Everything in FW.092, plus:
- Factory defaults (table at main 0x15897c, 0x198 bytes): Pro Mode +0x141 changed 05 (sRGB) -> 01 (User); User brightness +0x5d changed 0x3c -> 0x46 (70). The validity markers (bytes 0-3 = 1a07130b, 0x196 = a5a5) are untouched, so stored settings survive the flash and the new defaults apply after a factory reset (VCP 0x04 or the menu Reset).
- Settings map (offsets into 0xa802b878): +0x08 language (VCP CC), +0x09 brightness, +0x0a contrast, +0x11 colour-temp index (1 = Normal 6500 K), +0x12..14 RGB gains, +0x1a VCP DC, +0x58 per-mode brightness[10] (Game Modes 0-4, Pro Modes 0-5 at slot +4), +0x98 flags (bit 0x8000000 = Pro Mode active), +0x141 Pro Mode (0 Eco, 1 User, 2 Anti-Blue, 3 Movie, 4 Office, 5 sRGB), +0x142 Game Mode (0 User, 1 FPS, 2 Racing, 3 RTS, 4 RPG).
- EDID: all 36 store slots (0x118000-0x11c800) have their chromaticity set to Display P3 + D65 (bytes 0f 91 ae 52 43 b0 26 0f 50 54) with block checksums recomputed. The live EDID (DP/Type-C) is slot 0x118400 (copies at 0x118600, 0x11c400, 0x11c600). The DisplayID extension holds timings only.
- sha256 1433b414bd3e849695855c614c9329d9b1311004b8d03c7a0614b53c67232f49, sum16 0xE782.
- Status: built, NOT flashed.

## Native macOS brightness: not achievable (2026-10-24)
- macOS native external brightness goes over USB HID (VESA Monitor Control, page 0x80; brightness is 0x82:0x10). AppleUSBDisplays.kext only matches Apple VID 0x05AC with PIDs 0x92xx. LG UltraFine is the only non-Apple exception: macOS explicitly lists LG VID 0x043E with PIDs (e.g. 0x9A63, 0x9A70).
- The MSI presents one USB device to the Mac: "MSI Gaming Controller" 1462:3FA4, a full-speed generic HID tunnel (usage page 1/0, report IDs 1-4, 63-byte in/out) behind a VIA Labs hub (2109:2211). It's a separate MCU; its firmware isn't in the scaler image, so it can't be repurposed. The scaler has no USB link to the host.
- A virtual HID device on the Mac is refused by the kernel ("not entitled"; needs Apple-granted com.apple.developer.hid.virtual.device).
- The only remaining route would be external hardware (e.g. an RP2040 emulating the LG "USB Controls" HID: feature report 0, u16 LE 0-54000) relaying to DDC/CI. The user can't do that.
- Pairing of the HID controls to a specific screen likely uses a container ID (HIDDisplay framework APIs are keyed by ContainerID). Unconfirmed.
- Practical solution: DDC/CI brightness sync (e.g. MonitorControl).

## Wake measurement v2 (2026-10-24, on FW.092)
Three independent signals:
1. Scaler/DDC (tools/wakescope Swift): scaler stays ON during display sleep in every run ("light sleep"
   confirmed working). DDC + VCP D6=on + macOS-active all within ~1-6 ms on wake. So the SCALER is NOT
   the wake bottleneck on FW.092 (it never sleeps).
2. macOS external-display bring-up (tools/wakescope.py, parses DCP logs for display_id=2/dispext1):
   wake->HPD/DP-link ~120-150 ms; wake->transition-complete median **616 ms**. This ~600 ms is DP link
   training + macOS display reconfig — the real automated "display ready" time, firmware-comparable.
3. Physical panel/backlight-on instant: NOT captured by any Mac-side signal; needs slow-mo video.

Interpretation: the light-sleep patch keeps the scaler alive (more standby power) but the wake cost is
dominated by the ~600 ms DP-link bring-up + the panel-on, neither of which keeping the scaler awake
reduces. So FW.092 likely gives no perceptible wake improvement over stock deep standby — matches the
user's observation that it feels the same/slower. This supports flashing 027 (same wake, lower standby
power). After flashing 027: run `python3 -I tools/wakescope.py FW027 15 4` and the Swift wakescope to
compare; expect 027 scaler-during-sleep = "OFF (deep standby)". For true time-to-picture, one slow-mo
clip per firmware is the only ground truth.

## User stopwatch results (2026-10-25), seconds — stock vs FW.093 (light sleep) vs FW.094 (no light sleep)
| scenario | stock Win | stock Mac | 093 Win | 093 Mac | 094 Win | 094 Mac |
| cable reconnect | 7.00 | 4.84 | 7.44 | 5.00 | 7.49 | 5.16 |
| laptop standby -> picture | 4.63 | 3.39-3.52 | 3.64 | 3.17 | 3.59 | 3.32-5.0 |
| monitor power button on | 4.83 | 7.0 | 2.82 | 2.71 | 2.84 | 2.73 |
- Real win = power-button-on, 2-4 s faster: the no-logo patch (in both 093 and 094).
- Light sleep (093 vs 094): no measurable effect on Windows; Mac standby on 094 noisy (3.3-5.0), needs more samples.
- Cable reconnect unchanged: host-side DP link training + OS display enumeration dominate.

## 107 findings (other thread) — status
- ResetDPDelay2Sleep exists only in FW.107 (322UPF and 323UPF). In 323 FW.107 it is logged from
  APPTasksAfterDisplay ("reset ResetDPDelay2Sleep"): resets the DP no-signal -> sleep countdown once a
  picture is shown. It changes when the monitor goes to sleep, not how fast it wakes. Not portable:
  323 FW.107 is the 1XX hardware branch (references NT68503, different boot loader digest).
- HDMI EQ error-handling / retrain path: already present in 323UPF FW.027 (identical [EQ] strings).
- "Main core is Tensilica, not LEON": wrong for the Main partition we patch — it disassembles as SPARC
  and those patches (no-logo, light sleep) work on the hardware. Tensilica is the separate DSP.
- 322UPF files are a different model; nothing to take.

## Version reported over USB/DDC (what MSI Gaming Intelligence shows)
- Query "58001<0\r" -> reply "5b001<0" + 3 digits. Reply built by FUN_000500ac (main 0x500ac): the digits
  are HARDCODED as `or %g0,'0',%o2` @0x500bc, `or %g0,'2',%o1` @0x500c0, `or %g0,'7',%o0` @0x500b8,
  then FUN_0004f830(0x4a) builds the header from request-table entry 74 (table @0x166c30, 8 B/entry).
  This is separate from the OSD labels, which is why 091-093 still reported 027.
- patch_fw027.py now patches these (VERSION_REPLY) for every build. FW.093/FW.094 rebuilt; FW.094 reports 094.
- Panel-name reply (FUN_0005010c, entry 75) copies 15 bytes from main 0x1587e8.

## Fake unplug on wake — hub vs direct (2026-10-25, FW.093, Mac, tools/hpdwatch)
- Via HP Universal USB-C Multiport Hub -> monitor DP input (VCP 0x60 = 15): stays connected during sleep,
  but ~0.35 s after wake macOS logs "processing dual pipe plug state of 0" (HPD low = unplug); display back
  ~1.85 s after wake. Once HPD never came back (stuck until replug; macOS showed the mirroring message).
  Hub also limits 4K to 60 Hz and DDC is unreliable.
- Direct USB-C -> monitor Type-C input (15 vs 16): no drop ("plug state 3 is same"), display on 0.57 s
  after wake; 120 Hz; DDC + HID controller work.
- Not yet isolated: hub vs the monitor's DP-input path (would need a direct USB-C->DP cable test).
