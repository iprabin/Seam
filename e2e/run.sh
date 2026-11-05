#!/bin/sh
# Real windows, real keys and drags, a virtual display. Leaves your windows alone; takes the cursor for a few minutes.
# Needs ./build.sh run once. `e2e/run.sh grep-pattern` runs matching scenarios. Puts the real Seam back after.
cd "$(dirname "$0")/.." || exit 1
OUT=$(mktemp -d)
swift build -c release -Xswiftc -DE2E --build-path .build/e2e 2>&1 | grep -E "error|Compiling Seam" | grep error && exit 1
APP=$OUT/Seam.app
cp -R build/Seam.app "$APP"
cp .build/e2e/release/Seam "$APP/Contents/MacOS/Seam"
codesign --force --sign "$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/ {print $2; exit}')" "$APP" 2>/dev/null
clang -fobjc-arc -framework AppKit -o "$OUT/vdisplay" e2e/vdisplay.m || exit 1
swiftc -O -o "$OUT/driver" e2e/driver.swift || exit 1
pkill -x Seam; sleep 1
open "$APP" || { sleep 2; open "$APP"; }
sleep 2
"$OUT/driver" "$OUT" "$1"; code=$?
pkill -x vdisplay; pkill -x Seam; sleep 1
open build/Seam.app || { sleep 2; open build/Seam.app; }
exit $code
