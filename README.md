# MSI MAG 323UPF — custom firmware patches + macOS tools

Unofficial patches for the **MSI MAG 323UPF** (32" 4K 160 Hz, Novatek NT68501 scaler, AUO M320QAN02.9
panel), plus a set of macOS tools for using it with a Mac. Built by reverse-engineering MSI's stock
firmware FW.027.

> **Warning.** Flashing modified firmware is at your own risk. A failed or interrupted flash can leave the
> monitor unusable. This project is not affiliated with or endorsed by MSI. No firmware images are
> included; you build them yourself from MSI's official file.

## What the recommended build (FW.097) changes

| Change | Effect |
|---|---|
| MSI logo removed, including at cold power-on | Monitor shows a picture 2–4 s sooner after pressing its power button |
| Display P3 + D65 in all 36 stored EDIDs | macOS recognises and colour-manages the panel as P3 |
| **M-Book** Pro Mode (replaces the Office mode) | A neutral D65 / 6500K mode tuned to match a MacBook, selectable from the menu |
| Factory defaults: Pro Mode **User**, 60/60 | A reset lands in a neutral, universal mode (not Eco) |
| Version **FW.097** on the OSD *and* over USB/DDC | MSI Gaming Intelligence and the OSD both show the new version |

Everything else (refresh rates, timings, overdrive, HDR, menus) is stock. Earlier builds and the
experimental light-sleep one are in [CHANGELOG.md](CHANGELOG.md).

### Measured (seconds, stopwatch, Windows / Mac)

| Scenario | Stock FW.027 | FW.097 |
|---|---|---|
| Monitor power button on (cable connected) | 4.83 / 7.0 | **2.84 / 2.73** |
| Laptop wakes from standby | 4.63 / 3.4–3.5 | 3.59 / 3.3–5.0 |
| Cable reconnect | 7.0 / 4.84 | 7.49 / 5.16 (unchanged: host-side) |

The power-on gain is the logo removal; wake and reconnect are unchanged (that time is host-side DisplayPort
link training). These numbers are the same across the no-logo builds — M-Book and the colour changes don't
touch wake. An experimental "light sleep" patch (FW.092/093) gave **no** measurable wake improvement, so
FW.097 leaves standby stock.

## Which monitors this is for

Only the **MAG 323UPF on the 0XX firmware line**: stock firmware **FW.027**, OSD shows `FW.0xx`.
MSI's FW.107 file for this model is a different hardware revision (1XX line, different boot loader).
Do not use this on other models, including the MAG 322UPF or MAG 321UP.

## Build the firmware

You need MSI's official `MSI_MAG_323UPF_FW.027_E782.bin`:

```
SHA-256  c8720f6bffabdfe51cf39e889423cda4095c4f0dc406648ba1158a23d6b1a4b7
```

```sh
python3 -I tools/patch_fw027.py --097 MSI_MAG_323UPF_FW.027_E782.bin MSI_MAG_323UPF_FW.097_E782.bin
shasum -a 256 MSI_MAG_323UPF_FW.097_E782.bin
# expect f2a4698a74298f3b148a1846e5d2f03843231be27bd0c4c73e875a3d8518e0d8
```

The script refuses any input that is not the stock FW.027 image, checks every byte it changes, and keeps
the stock boot region and whole-file checksum (`E782`), so keep that suffix in the file name.
Other options: no flag = FW.091, `--light-sleep` = FW.092, `--093`, `--094`, `--096` (see CHANGELOG).

## Flash it

Use **MSI Gaming Intelligence on Windows**, following MSI's own monitor firmware upgrade guide, and select
the `MSI_MAG_323UPF_FW.097_E782.bin` file you built. Keep the cable connected and the monitor powered
until it finishes, then do a menu **Reset** once so the new defaults load. To go back, flash the stock
FW.027 file the same way. (Untested: whether MSI's app treats FW.027 as a downgrade from FW.097 and refuses.)

There is no working macOS flasher yet; see [Native macOS flashing](#native-macos-flashing-research).

## macOS tools

Build any tool with `swiftc -O -o <name> tools/ddc.swift tools/<tool>/main.swift` (tools that do not
talk DDC don't need `ddc.swift`).

| Tool | What it does |
|---|---|
| `msiflash status` / `identify` | Display mode, input, power, brightness, contrast, preset, and the monitor's model, firmware version, panel, calibration checksum over USB (read-only) |
| `whitematch` | Match the MSI's white point to the MacBook screen by eye (adjusts RGB gains over DDC) |
| `setprofile` | Show/assign/reset the MSI's ColorSync profile |
| `ddcprobe` | Read VCP codes once (read-only) |
| `hpdwatch` | Checks whether the display drops out of macOS's display list during sleep or right after wake |
| `wakescope`, `wakescope.py`, `wakebench`, `wakecycle.sh` | Wake-time measurement helpers |
| `patch_fw027.py` | The firmware patcher |
| `ghidra/*.java` | Ghidra headless scripts used for the analysis |

`msiflash` also contains ISP research commands (`scaler-id`, `validate`, `diag`, `recover`). **Don't run
them** unless you are continuing the research: they can leave the monitor's USB controller stuck until you
unplug both the USB-C and power cables for 30 seconds.

## What we tried that didn't pan out

Saving you the time:

- **Native macOS brightness keys and slider.** macOS only offers native brightness control for external
  displays that speak Apple's USB display protocol, and its driver only accepts Apple displays and the LG
  UltraFine. The monitor's USB side is a separate Nuvoton microcontroller whose firmware isn't in MSI's
  update file, so it can't be made to pose as an UltraFine, and a virtual HID device on the Mac is blocked
  without an Apple entitlement. What works is DDC: a brightness app such as MonitorControl mirrors the
  MacBook's brightness to the MSI. The only other route would be extra hardware (a small microcontroller
  emulating an UltraFine's USB controls), which we didn't pursue.
- **Faster wake using MSI's own light-sleep mode.** FW.027 already contains a light-sleep path for display
  sleep (panel off, scaler and memory stay powered), but nothing in the firmware ever turns it on. We
  forced it on (FW.092/093). Wake from standby didn't get faster on Windows or Mac, because most of the
  wait is the laptop retraining the DisplayPort link and re-detecting the display. FW.094 leaves it off
  to save standby power.
- **Hidden Display P3 / Adobe RGB modes.** Those names exist in the firmware (along with Calibration 1–3),
  but only as text; this model has no colour tables behind them. The P3 EDID patch is what makes macOS
  treat the panel as P3.
- **Porting fixes from newer MSI firmware.** MSI's FW.107 for this model is built for a different hardware
  revision, so its code can't be moved over. Its sleep-related change (`ResetDPDelay2Sleep`) affects when
  the monitor goes to sleep, not how fast it wakes, and its HDMI link-error recovery is already in FW.027.
  The MAG 322UPF and MAG 321UP X24 firmware are different models with nothing transferable.
- **More HDMI 2.1 bandwidth.** Nothing to unlock: the HDMI EDIDs already advertise the maximum (48 Gbps,
  DSC, VRR 48–160 Hz, ALLM).
- **Turning off Auto Scan** in the monitor's menu: no measurable change to wake or reconnect times.
- **Skipping DisplayPort link training on resume** (considered, not tried). The monitor can advertise
  "no-handshake" link training with a one-bit change, but the laptop decides whether to use it, and if
  the link doesn't lock you get a black screen until you replug.
- **Using a USB-C hub.** Through an HP USB-C multiport hub on the DP input, the Mac saw a fake unplug on
  every wake (about 1.2 s slower, windows rearranged, and once the display didn't come back until
  replugged), and 4K was capped at 60 Hz. Plugged directly into the monitor's USB-C, wake is clean
  (display back about 0.6 s after the Mac wakes it) and 4K runs at up to 160 Hz.

## Native macOS flashing (research)

Not finished. What works on macOS: the full USB HID transport to the monitor's controller (1462:3FA4) and
all normal-mode reads. Entering ISP with MSI's own unlock command (`"580040:\r"` on report ID 1) is safe
on this unit, but the scaler did not answer ISP register reads afterwards, so erase/program was never
attempted. A USB capture of MSI's Windows tool during a real flash would likely close the gap. Full notes:
[analysis/isp/PROTOCOL.md](analysis/isp/PROTOCOL.md).

The independent [msi-monitor-updater](https://github.com/danielheimburg/msi-monitor-updater) project
(MIT) was invaluable for the HID transport details. On this unit its HID-descriptor and panel-name checks
reject the controller, and the ISP identify command it uses (`A0 …` on report ID 4), sent from our own
tool, put this unit's controller into its Nuvoton bootloader (recovered with a full power cut).

## Layout

```
tools/            patcher + macOS tools (Swift, Python, Ghidra scripts)
analysis/         research notes, ISP protocol notes, wake measurements
CHANGELOG.md      every build, with hashes
```

## License

MIT for the code and documentation in this repository. MSI firmware and software are not included and
remain MSI's property.
