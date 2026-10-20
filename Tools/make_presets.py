#!/usr/bin/env python3
"""Generates the shipped preset JSON files in Brumbrum/Engines.

The JSON files are the source of truth for the app; this script only exists so
the seven presets stay consistent with each other. Edit and re-run, or edit the
JSON directly.
"""
import json, os

OUT = os.path.join(os.path.dirname(__file__), "..", "Brumbrum", "Engines")

def even(n, step):
    return [i * step for i in range(n)]

def combustion(id, name, cyl, angles, bank_of, banks, idle, redline, limiter,
               gears, final, up, down, shift_ms, slip, sharp, gain, variance,
               pipe_ms, fb, res, overrun, intake, orders, mix, turbo=None, wander=25):
    return {
        "id": id, "name": name, "family": "combustion", "version": 1,
        "geometry": {"cylinders": cyl, "strokes": 4, "banks": banks, "cycleDegrees": 720,
                     "firingAngles": angles, "bankOf": bank_of},
        "range": {"idleRpm": idle, "idleWanderRpm": wander, "redlineRpm": redline, "limiter": limiter},
        "drivetrain": {"mode": "geared", "gearRatios": gears, "finalDrive": final,
                       "upshiftRpm": up, "downshiftRpm": down, "shiftMs": shift_ms, "launchSlip": slip},
        "excitation": {"grainSharpness": {"atZeroLoad": sharp[0], "atFullLoad": sharp[1]},
                       "grainGain": {"atZeroLoad": gain[0], "atFullLoad": gain[1]},
                       "cylinderVariance": variance},
        "exhaust": {"pipeLengthMs": pipe_ms, "pipeFeedback": fb,
                    "resonances": [{"hz": h, "q": q, "gain": g} for h, q, g in res],
                    "overrun": {"crackleDensity": overrun[0], "gain": overrun[1], "thresholdLoad": overrun[2]}},
        "intake": {"noiseGain": intake[0], "cutoffHzAtIdle": intake[1], "cutoffHzAtRedline": intake[2],
                   "loadSensitivity": intake[3]},
        "orders": [{"order": o, "gain": g} for o, g in orders],
        "turbo": turbo,
        "mix": {"masterGain": mix[0], "exhaustToIntake": mix[1], "windGain": mix[2]},
    }

SIX = [3.2, 2.0, 1.4, 1.0, 0.8, 0.65]
HARD = lambda hz, d: {"mode": "hardCut", "cutHz": hz, "depth": d}
SOFT = lambda hz, d: {"mode": "softCut", "cutHz": hz, "depth": d}

presets = [
    combustion("inline-4", "Inline-4", 4, even(4, 180), [0, 0, 0, 0], 1,
               850, 7000, HARD(20, 0.9), [3.5, 2.1, 1.45, 1.1, 0.9, 0.75], 4.1, 6500, 2300, 280, 0.6,
               (0.35, 0.85), (0.2, 1.0), 0.05, 4.0, 0.30,
               [(140, 5, 1.0), (420, 4, 0.6), (1100, 3, 0.35)], (0.1, 0.3, -0.4),
               (0.55, 400, 3500, 0.8),
               [(2.0, [[800, 0.5], [7000, 0.7]]), (4.0, [[800, 0.15], [7000, 0.3]])],
               (0.8, 0.6, 0.2)),
    combustion("inline-4-turbo", "Inline-4 Turbo", 4, even(4, 180), [0, 0, 0, 0], 1,
               850, 6800, HARD(20, 0.9), [3.5, 2.1, 1.45, 1.1, 0.9, 0.75], 4.1, 6200, 2200, 260, 0.6,
               (0.3, 0.8), (0.2, 1.0), 0.05, 4.5, 0.28,
               [(130, 5, 1.0), (380, 4, 0.55), (1000, 3, 0.3)], (0.15, 0.3, -0.4),
               (0.45, 350, 3000, 0.9),
               [(2.0, [[800, 0.5], [6800, 0.6]]), (4.0, [[800, 0.12], [6800, 0.25]])],
               (0.8, 0.65, 0.2),
               turbo={"spoolRate": 2.2, "maxBoost": 1.4, "whistleHzAtMaxBoost": 5200, "blowoffGain": 0.7}),
    combustion("v6-90-splitpin", "V6 (90°, split-pin)", 6, even(6, 120), [0, 1, 0, 1, 0, 1], 2,
               750, 6800, HARD(18, 0.85), SIX, 3.6, 6000, 2100, 260, 0.65,
               (0.3, 0.85), (0.18, 1.0), 0.03, 6.0, 0.33,
               [(110, 5, 1.0), (300, 4, 0.55), (800, 3, 0.3)], (0.2, 0.35, -0.35),
               (0.45, 320, 3000, 0.8),
               [(1.5, [[800, 0.2], [6800, 0.2]]), (3.0, [[800, 0.55], [6800, 0.7]]), (6.0, [[800, 0.15], [6800, 0.3]])],
               (0.8, 0.68, 0.2)),
    combustion("crossplane-v8", "Crossplane V8", 8, even(8, 90), [0, 1, 0, 1, 1, 0, 1, 0], 2,
               750, 6500, HARD(18, 0.9), SIX, 3.44, 6000, 2200, 250, 0.7,
               (0.25, 0.9), (0.15, 1.0), 0.03, 7.5, 0.35,
               [(85, 6, 1.0), (230, 4, 0.6), (620, 3, 0.3)], (0.4, 0.5, -0.3),
               (0.4, 300, 2800, 0.8),
               [(0.5, [[800, 0.30], [3000, 0.50], [6500, 0.20]]), (1.5, [[800, 0.2], [6500, 0.15]]),
                (2.5, [[800, 0.15], [6500, 0.12]]), (4.0, [[800, 0.5], [6500, 0.8]])],
               (0.8, 0.7, 0.2)),
    combustion("flatplane-v8", "Flatplane V8", 8, even(8, 90), [0, 1, 0, 1, 0, 1, 0, 1], 2,
               950, 8500, HARD(22, 0.95), SIX, 3.7, 8000, 3000, 220, 0.6,
               (0.4, 0.95), (0.18, 1.0), 0.02, 4.5, 0.30,
               [(140, 5, 1.0), (380, 4, 0.6), (950, 3, 0.35)], (0.25, 0.4, -0.35),
               (0.5, 400, 3800, 0.85),
               [(2.0, [[1000, 0.3], [8500, 0.3]]), (4.0, [[1000, 0.6], [8500, 0.85]]), (8.0, [[1000, 0.1], [8500, 0.3]])],
               (0.8, 0.7, 0.2), wander=20),
    combustion("v10", "V10", 10, even(10, 72), [i % 2 for i in range(10)], 2,
               1000, 8500, HARD(24, 0.95), SIX, 3.9, 8000, 3000, 200, 0.6,
               (0.4, 0.95), (0.18, 1.0), 0.02, 4.0, 0.30,
               [(160, 5, 1.0), (450, 4, 0.6), (1200, 3, 0.35)], (0.3, 0.4, -0.35),
               (0.45, 450, 4000, 0.85),
               [(2.5, [[1000, 0.1], [8500, 0.1]]), (5.0, [[1000, 0.6], [8500, 0.85]]), (10.0, [[1000, 0.15], [8500, 0.3]])],
               (0.8, 0.72, 0.2), wander=20),
    combustion("v12", "V12", 12, even(12, 60), [i % 2 for i in range(12)], 2,
               800, 8000, SOFT(14, 0.6), SIX, 3.4, 7500, 2800, 240, 0.6,
               (0.3, 0.8), (0.15, 0.9), 0.008, 3.5, 0.28,
               [(200, 4, 1.0), (520, 3, 0.6), (1400, 2.5, 0.35)], (0.15, 0.3, -0.4),
               (0.2, 400, 3200, 0.6),
               [(3.0, [[800, 0.35], [8000, 0.4]]), (6.0, [[800, 0.8], [8000, 0.95]]), (12.0, [[800, 0.2], [8000, 0.4]])],
               (0.8, 0.85, 0.2), wander=12),
    {
        "id": "futuristic", "name": "Futuristic", "family": "synthetic", "version": 1,
        "geometry": None,
        "range": {"idleRpm": 900, "idleWanderRpm": 15, "redlineRpm": 12000, "limiter": SOFT(10, 0.3)},
        "drivetrain": {"mode": "direct", "gearRatios": [], "finalDrive": 1, "upshiftRpm": 0,
                       "downshiftRpm": 0, "shiftMs": 0, "launchSlip": 0, "topSpeedKph": 250},
        "excitation": None,
        "generator": {"type": "fm", "baseOrder": 4, "fmRatio": 1.5, "fmIndexAtZeroLoad": 0.4,
                      "fmIndexAtFullLoad": 2.5, "detuneCents": 12, "voices": 3,
                      "formantLowHz": 400, "formantHighHz": 3200, "formantQ": 2.5, "gain": 0.6},
        "exhaust": None,
        "intake": {"noiseGain": 0.15, "cutoffHzAtIdle": 500, "cutoffHzAtRedline": 4000, "loadSensitivity": 0.6},
        "orders": [{"order": 2.0, "gain": [[900, 0.25], [12000, 0.2]]},
                   {"order": 4.0, "gain": [[900, 0.5], [12000, 0.5]]},
                   {"order": 8.0, "gain": [[900, 0.15], [12000, 0.35]]},
                   {"order": 12.0, "gain": [[900, 0.05], [12000, 0.2]]}],
        "turbo": None,
        "mix": {"masterGain": 0.75, "exhaustToIntake": 0.8, "windGain": 0.2},
    },
]

os.makedirs(OUT, exist_ok=True)
for p in presets:
    with open(os.path.join(OUT, p["id"] + ".json"), "w") as f:
        json.dump(p, f, indent=2)
        f.write("\n")
print("wrote", len(presets), "presets")
