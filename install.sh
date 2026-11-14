#!/bin/zsh
# Builds Hum, installs it to /Applications (or ~/Applications if that isn't writable) and starts it.
set -e
cd "$(dirname "$0")"
./build.sh
DIR=/Applications
[ -w "$DIR" ] || { DIR="$HOME/Applications"; mkdir -p "$DIR"; }
pkill -x Hum 2>/dev/null || true
rm -rf "$DIR/Hum.app" && cp -R build/Hum.app "$DIR/Hum.app"
open "$DIR/Hum.app"
echo "Installed to $DIR/Hum.app. Tick 'Launch at login' in the menu to start it at login."
echo "Uninstall: untick 'Launch at login', quit Hum, then rm -rf $DIR/Hum.app"
