#!/bin/zsh
# Build msi-brightness-sync and install it as a per-user LaunchAgent (starts at login, restarts if it exits).
# Usage: tools/brightness-sync/install.sh [--min N] [--max N]      Uninstall: tools/brightness-sync/install.sh --uninstall
set -e
here=${0:A:h}
label=com.user.msi-brightness-sync
dest="$HOME/Library/Application Support/msi-brightness-sync"
plist="$HOME/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
if [[ "$1" == "--uninstall" ]]; then
  rm -f "$plist"; rm -rf "$dest"; echo "uninstalled"; exit 0
fi

mkdir -p "$dest" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O -o "$dest/msi-brightness-sync" "$here/../ddc.swift" "$here/main.swift"

args=""
for a in "$@"; do args+="    <string>$a</string>
"; done
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dest/msi-brightness-sync</string>
$args  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/msi-brightness-sync.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/msi-brightness-sync.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed and running ($label)"
