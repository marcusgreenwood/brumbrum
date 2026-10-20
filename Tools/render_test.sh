#!/bin/sh
# Renders every preset through a scenario offline (macOS) and prints levels.
# Usage: Tools/render_test.sh [scenario-id] [out-dir]
set -e
cd "$(dirname "$0")/.."
OUT="${2:-/tmp/brumbrum-render}"
mkdir -p "$OUT"
swiftc -O -o "$OUT/render_test" \
  Brumbrum/Model/EngineDefinition.swift \
  Brumbrum/Synth/DSP.swift Brumbrum/Synth/TripleBuffer.swift \
  Brumbrum/Synth/SynthProgram.swift Brumbrum/Synth/SynthKernel.swift \
  Brumbrum/Vehicle/Powertrain.swift Brumbrum/Vehicle/SimulatedDrive.swift \
  Tools/RenderTest/main.swift
"$OUT/render_test" Brumbrum/Engines "$OUT" "${1:-lap}"
