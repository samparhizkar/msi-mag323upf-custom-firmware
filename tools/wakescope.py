#!/usr/bin/env python3
"""wakescope: measure external-display wake time from macOS DCP logs, for firmware comparison.

For each cycle: sleep the display, wait, wake it, then parse the unified log for the external
display's power-on sequence and report:
  - wake-request -> HPD/DP-link bring-up
  - wake-request -> display-state transition complete  (best automated proxy for "ready")
It does NOT capture the physical backlight/panel-on instant (that needs a slow-mo video), but the
transition-complete span includes DP link training and is comparable across firmwares.

Usage: tools/wakescope.py <label> [sleepSeconds=15] [runs=4]
Run with -I: python3 -I tools/wakescope.py FW092
"""
import subprocess, sys, time, re, statistics

label = sys.argv[1] if len(sys.argv) > 1 else "run"
sleep_s = float(sys.argv[2]) if len(sys.argv) > 2 else 15
runs = int(sys.argv[3]) if len(sys.argv) > 3 else 4


def logs_since(start_epoch):
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(start_epoch))
    out = subprocess.run(["/usr/bin/log", "show", "--start", start, "--style", "compact"],
                         capture_output=True, text=True).stdout
    return out.splitlines()


def ts(line):
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
    if not m:
        return None
    return time.mktime(time.strptime(m.group(1)[:19], "%Y-%m-%d %H:%M:%S")) + float("0." + m.group(1).split(".")[1])


def measure(lines, wake_epoch):
    t_req = t_hpd = t_done = None
    for ln in lines:
        t = ts(ln)
        if t is None or t < wake_epoch - 1:
            continue
        if t_req is None and "request_power_change fId 0" in ln and "powerstate 1" in ln:
            t_req = t
        if t_req is not None:
            if t_hpd is None and "HPD notification registered" in ln and "dispext" in ln:
                t_hpd = t
            if "complete_display_state_transition display_id=2" in ln:
                t_done = t   # keep the last one in the window
    base = t_req or wake_epoch
    return (None if t_hpd is None else (t_hpd - base),
            None if t_done is None else (t_done - base))


print(f"wakescope label={label} sleep={int(sleep_s)}s runs={runs}")
print("measures macOS external-display bring-up (incl. DP link training); NOT the physical panel-on instant.")
hpds, dones = [], []
for i in range(1, runs + 1):
    wake_mark = time.time()
    subprocess.run(["pmset", "displaysleepnow"])
    time.sleep(sleep_s)
    wake_epoch = time.time()
    subprocess.run(["caffeinate", "-u", "-t", "2"])
    time.sleep(5)
    hpd, done = measure(logs_since(wake_mark), wake_epoch)
    hpds.append(hpd); dones.append(done)
    def ms(x): return "n/a" if x is None else f"{x*1000:.0f} ms"
    print(f"  run {i}: wake->HPD {ms(hpd)} | wake->transition-complete {ms(done)}")
    time.sleep(5)

good = [d for d in dones if d is not None]
gh = [h for h in hpds if h is not None]
if good:
    print(f"\nSUMMARY [{label}]: median wake->transition-complete {statistics.median(good)*1000:.0f} ms"
          + (f", median wake->HPD {statistics.median(gh)*1000:.0f} ms" if gh else ""))
else:
    print(f"\n[{label}] could not parse external-display events; see raw log.")
