**Title:** I reverse-engineered the MSI MAG 323UPF firmware: no boot logo (2–4 s faster power-on), P3 EDID for Macs, plus a pile of macOS tools

---

I use a MAG 323UPF with a MacBook and got curious about why it took so long to show a picture, so I spent
some time pulling apart MSI's stock firmware (FW.027). The result is a small, reproducible patch set and
some Mac tools. Everything is here: **https://github.com/samparhizkar/msi-mag323upf-custom-firmware**

**What the patched firmware (FW.094) changes**

- **MSI logo removed**, including after a cold power-on. Pressing the monitor's power button now gets you a
  picture in ~2.8 s instead of 4.8 s (Windows) / 7 s (Mac).
- **Display P3 colour data in the EDID**, so macOS recognises and colour-manages the panel as P3.
- **Factory defaults** set to User mode / brightness 70 instead of Eco.
- **Reports FW.094** both on the OSD and to MSI Gaming Intelligence (the version the app reads turned out
  to be hardcoded separately from the OSD label).

Nothing else is touched: refresh rates, timings, overdrive, HDR and menus are stock.

**Stopwatch results (Windows / Mac), stock → FW.094**

| | Stock | FW.094 |
|---|---|---|
| Monitor power button on | 4.83 / 7.0 s | 2.84 / 2.73 s |
| Laptop wakes from standby | 4.63 / ~3.5 s | 3.59 / ~3.3–5.0 s |
| Cable reconnect | 7.0 / 4.8 s | unchanged (that part is the laptop) |

I also tried a "light sleep" patch that keeps the scaler powered in standby. It made no measurable
difference, so the recommended build leaves standby stock.

**No firmware files are shared.** You download MSI's official FW.027 and run a Python script that checks
it's the exact stock file, patches it, and keeps the stock boot loader and checksum. The output is
byte-identical for everyone (hash in the README). You still flash it with MSI Gaming Intelligence on
Windows.

**Only for the 323UPF on the 0XX firmware line** (stock FW.027, OSD shows FW.0xx). MSI's FW.107 for this
model is a different hardware revision. Don't use it on other models.

**Things I tried that didn't work (so you don't have to)**

- **Native macOS brightness keys.** macOS only does native brightness for Apple displays and the LG
  UltraFine, over a USB protocol the MSI's separate USB chip can't be reprogrammed to speak. The working
  answer is DDC sync (included), which makes the MacBook's brightness keys and auto-brightness drive the MSI.
- **MSI's own hidden light-sleep mode.** It's in the stock firmware but never enabled. Forcing it on didn't
  make wake from standby any faster; the laptop renegotiating DisplayPort is most of the wait.
- **Hidden P3 / Adobe RGB modes.** Only the names exist in the firmware, no colour data behind them.
- **USB-C hubs.** Through an HP USB-C hub the Mac saw a fake unplug on every wake and 4K was capped at 60 Hz.
  Plugged straight into the monitor's USB-C it wakes cleanly and runs 4K at up to 160 Hz.

**Mac tools in the repo:** brightness sync (MacBook brightness keys/auto-brightness also drive the MSI over
DDC), a white-point matcher, a status/identity reader over USB, and wake/unplug test tools.

**Help wanted:** I got most of the way to a native macOS flasher (the USB protocol works, and I found MSI's
real update-mode command) but the scaler doesn't answer the flash commands yet. If anyone can capture
the USB traffic of MSI's Windows tool during a real update (Wireshark + USBPcap), that would probably
finish it. Details in the repo.

**Usual warning:** flashing modified firmware is at your own risk. An interrupted flash can brick the
monitor. Not affiliated with MSI.
