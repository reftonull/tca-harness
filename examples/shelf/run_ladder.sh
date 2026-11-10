#!/bin/sh
# Build Shelf, then run every testing pattern with no bugs and with SHELF_BUGS=all, and print which
# pattern caught which planted bug. Needs Swift 6.3+, Python 3.11+; rung 2 needs xcodegen + FlowDeck
# and the simulator in flowdeck.json (pass --skip-ui to leave it out). Extra arguments go to ladder.py.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"
skip_ui=0
for arg in "$@"; do [ "$arg" = "--skip-ui" ] && skip_ui=1; done
echo "building shelf-headless (debug)"
swift build -q
if [ "$skip_ui" = 0 ]; then
  echo "building the iOS app (xcodegen + flowdeck)"
  xcodegen generate --quiet
  flowdeck build --config flowdeck.json >/dev/null
fi
exec python3 ladder.py "$@"
