#!/bin/zsh
# Put all displays to sleep and wake them, several times, for filming wake time.
# Usage: tools/wakecycle.sh [cycles=3] [sleepSeconds=30]
cycles=${1:-3}
sleep_s=${2:-30}
echo "Start filming now. First sleep in 5 s."
sleep 5
for i in $(seq 1 $cycles); do
  echo "cycle $i/$cycles: displays off for ${sleep_s}s"
  pmset displaysleepnow
  sleep $sleep_s
  caffeinate -u -t 1          # wake: the MacBook screen lights up immediately
  echo "cycle $i: woke at $(date +%H:%M:%S)"
  sleep 12                    # give the MSI time to show a picture before the next cycle
done
echo "Done. You can stop filming."
