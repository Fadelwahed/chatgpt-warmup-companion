#!/bin/sh
# Runs the Swift Testing suite. Command Line Tools 6.4.2 does not pass the Testing macro plugin
# path by itself (observed 2026-11-20), so it is given explicitly.
set -eu
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$PLUGINS" ]; then exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"; fi
exec swift test "$@"
