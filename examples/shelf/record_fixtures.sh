#!/bin/sh
# Re-record fixtures/shelf from the journeys, each against a fresh server.py (the `record` target),
# then print the fixture coverage. match.json (the matching rules) is kept. Run from anywhere.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"
swift build -q
find fixtures/shelf -name '*.json' ! -name match.json -delete
SHELF_BUGS= exec ../../scripts/tca fixtures record journeys/*.toml --target record --strict
