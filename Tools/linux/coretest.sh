#!/bin/sh
# Builds and runs the core tests without a Mac, against Tools/linux/simd.swift (a small
# stand-in for Apple's simd module: just what Core uses). From the project folder, with
# Docker:
#
#   docker run --rm -v "$PWD":/repo -w /repo swift:6.1-noble sh Tools/linux/coretest.sh
#
# Takes several minutes. Three checks time how long painting takes and fail here: the
# stand-in's maths is much slower than Apple's. Everything else should pass, as on a Mac.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/Tools/build/linux
mkdir -p "$out"
cd "$out"
swiftc -O -parse-as-library -emit-module -emit-library -static -module-name simd \
    -emit-module-path "$out/simd.swiftmodule" -o "$out/libsimd.a" "$root/Tools/linux/simd.swift"
swiftc -O -swift-version 6 -I "$out" -L "$out" -lsimd -o "$out/coretest" \
    "$root/Tools/coretest/main.swift" "$root"/ChameleonHunt/Core/*.swift
"$out/coretest"
