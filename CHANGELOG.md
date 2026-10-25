# MSI MAG 323UPF custom firmware — changelog

All builds start from stock **FW.027** (`MSI_MAG_323UPF_FW.027_E782.bin`, hardware line 0XX) and are
produced by `tools/patch_fw027.py`. Every build keeps the stock boot region (first 0x6000 bytes) and the
stock whole-file checksum (E782), so the file name suffix MSI's updater expects still matches.

Measured times are the owner's stopwatch results (seconds, Windows / Mac), stock → this build.

Since 2026-10-25 every build also reports its own version over USB/DDC (what MSI Gaming Intelligence
shows). Images built before that date reported 027 there even though the OSD showed the new version.

## FW.097 — recommended
Everything in FW.094 plus an **M-Book** Pro Mode for Mac users.
- The **Office** Pro Mode is relabelled **M-Book** (all 10 menu/language slots) and tuned to match a
  MacBook: 6500K / D65, neutral, brightness and contrast 60 — the same values as stock User mode.
  (The contrast test confirmed this panel clips above 70; 60 keeps clean highlight headroom.)
- **User** mode is left exactly stock, and the default Pro Mode is **User** (neutral for any owner).
  M-Book is there in the menu; selecting it once makes the monitor boot into it.
- Everything else matches FW.094 (no logo, Display P3 EDID, no light sleep). Wake times unchanged.
- Reports **097** over USB/DDC and on the OSD.
- Built with `--097`.

SHA-256: `f2a4698a74298f3b148a1846e5d2f03843231be27bd0c4c73e875a3d8518e0d8`

## FW.094
Everything in FW.093 **except** light sleep (the monitor uses stock deep standby again).
- Monitor power button on: 4.83 / 7.0 → 2.84 / 2.73
- Laptop wakes from standby: 4.63 / 3.4–3.5 → 3.59 / 3.3–5.0
- Cable reconnect: unchanged (host-side DisplayPort link training dominates)
- Reports **094** over USB/DDC (MSI Gaming Intelligence) as well as on the OSD.

SHA-256: `afcc75c966a530833afc1c1c48ec6ece8e87012a3565ea5535314b888b17ded0`

## FW.093
FW.092 plus:
- Factory defaults: Pro Mode = User, brightness 70 (instead of Eco).
- EDID: Display P3 primaries with D65 white in all 36 stored EDID slots (checksums recomputed), so
  macOS reports and colour-manages the panel as P3.
- Reports **093** over USB/DDC.
- Measured: same as FW.094 within noise — light sleep gave no measurable wake gain.

SHA-256: `4eb2c0126d5601de85b7ee27ebc4e873543c9962888efa314e883922f6c20a3a`

## FW.092 — experimental
FW.091 plus:
- Light sleep: display sleep always takes the panel-off path and skips deep standby
  (`SYSAPI_PowerSaving`), keeping the scaler and DDR powered. Higher standby power; no measured benefit.

SHA-256: `c8ff03ecd43870b113e56373dfa498b647847e2a4123a44bbcc1c9b60880f3a8`

## FW.091
- No MSI logo, including after a cold power-on.
- OSD and factory menu show FW.091.

SHA-256: `d881634015d7ac7fdbacb4600ad783bb631aa8af5b03b5519ca960a388896e65`

## Not changed in any build
- Refresh rates, panel timing, overdrive, HDR, OSD menus.
- DisplayPort capability table (DPCD): DP 1.2/1.4, HBR2, 4 lanes; fast "no-handshake" link training
  stays off.
- HDMI 2.1 link-equalisation error recovery: already present in stock FW.027.
