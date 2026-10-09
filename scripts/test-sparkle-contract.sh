#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
framework="gui/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
temp="$(mktemp -d "${TMPDIR:-/tmp}/claudio-sparkle-contract.XXXXXX")"
trap 'rm -rf "$temp"' EXIT
swiftc -F "$framework" -framework Sparkle -Xlinker -rpath -Xlinker "$root/$framework" scripts/test-sparkle-contract.swift -o "$temp/comparator"
"$temp/comparator"
python3 scripts/test-sparkle-signatures.py "$temp"
