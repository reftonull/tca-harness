#!/bin/sh
# Re-record fixtures/shelf against a fresh server.py for each journey. Run from anywhere.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TCA="$HERE/../../scripts/tca"
cd "$HERE"
swift build -q
rm -rf fixtures/shelf
for journey in fixtures/record-sweep.toml journeys/add-book.toml journeys/mark-read.toml journeys/delete-book.toml journeys/search.toml; do
  python3 server.py --quiet --port 8799 </dev/null >/dev/null 2>&1 &
  server=$!
  sleep 0.5
  SHELF_BUGS= "$TCA" journey run "$journey" --target live --network record || { kill $server; exit 1; }
  kill $server
  wait $server 2>/dev/null || true
done
ls fixtures/shelf
