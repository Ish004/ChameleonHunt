#!/bin/sh
# Builds the offline tools against the app's Core sources.
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/Tools/build}
mkdir -p "$out"
xcrun swiftc -O -swift-version 6 -o "$out/preview" "$root/Tools/preview/main.swift" "$root"/ChameleonHunt/Core/*.swift
xcrun swiftc -O -swift-version 6 -o "$out/coretest" "$root/Tools/coretest/main.swift" "$root"/ChameleonHunt/Core/*.swift
xcrun swiftc -O -o "$out/frames" "$root/Tools/frames/main.swift"
xcrun swiftc -O -swift-version 6 -o "$out/sounds" "$root/Tools/sounds/main.swift" "$root"/ChameleonHunt/Core/SoundSynth.swift
xcrun swiftc -O -swift-version 5 -o "$out/storeshots" "$root/Tools/storeshots/main.swift" "$root"/ChameleonHunt/Core/*.swift
xcrun swiftc -O -o "$out/montage" "$root/Tools/mont/main.swift"
echo "built $out/preview, coretest, frames, montage, sounds and storeshots"
