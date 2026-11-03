#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

python3 build_assets.py

mkdir -p bin
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -framework AppKit -framework ImageIO -framework Carbon \
  CodexPet.swift -o bin/CodexPet

echo "built $(pwd)/bin/CodexPet"
