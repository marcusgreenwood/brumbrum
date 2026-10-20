#!/bin/sh
# Compares the old GPS-led speed filter with SpeedFusion on simulated drives.
set -e
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/brumbrum-fusion}"
mkdir -p "$OUT"
swiftc -O -o "$OUT/fusion_test" \
  Brumbrum/Model/EngineDefinition.swift Brumbrum/Vehicle/Powertrain.swift \
  Brumbrum/Vehicle/SimulatedDrive.swift Brumbrum/Vehicle/SpeedFusion.swift \
  Tools/FusionTest/main.swift
"$OUT/fusion_test"
